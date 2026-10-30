// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use super::*;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const RELEASE_ID: u64 = 42;
const LOOPBACK_BIND: &str = "127.0.0.1:0";
const IO_DEADLINE: Duration = Duration::from_secs(10);
const ACCEPT_INTERVAL: Duration = Duration::from_millis(5);
const MAXIMUM_HEADER_BYTES: usize = 16 * 1024;
const MAXIMUM_BODY_BYTES: usize = 1024 * 1024;

struct Request {
    headers: String,
    body: Vec<u8>,
}

fn workspace(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "gleam-mutants-github-{label}-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir(&path).unwrap();
    path
}

fn isolate(command: &mut Command, directory: &Path) {
    let path = std::env::var_os("PATH").unwrap();
    command
        .env_clear()
        .env("PATH", path)
        .env("GH_CONFIG_DIR", directory)
        .env("XDG_STATE_HOME", directory.join("state"))
        .env("XDG_CACHE_HOME", directory.join("cache"))
        .env("XDG_DATA_HOME", directory.join("data"))
        .env("GH_HOST", "github.com")
        .env("GH_TOKEN", "unused-local-http-fixture")
        .env("GH_PROMPT_DISABLED", "1");
}

fn exchange<T>(status: &str, response: &[u8], run: impl FnOnce(&str) -> T) -> (T, Request) {
    let listener = TcpListener::bind(LOOPBACK_BIND).unwrap();
    let address = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let status = status.to_owned();
    let response = response.to_vec();
    let server = thread::spawn(move || -> Result<Request, String> {
        let deadline = Instant::now() + IO_DEADLINE;
        let mut socket = loop {
            match listener.accept() {
                Ok((socket, _)) => break socket,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err("inconclusive: gh fixture connection timed out".into());
                    }
                    thread::sleep(ACCEPT_INTERVAL);
                }
                Err(error) => return Err(format!("accept gh fixture: {error}")),
            }
        };
        socket
            .set_read_timeout(Some(IO_DEADLINE))
            .map_err(|error| error.to_string())?;
        socket
            .set_write_timeout(Some(IO_DEADLINE))
            .map_err(|error| error.to_string())?;
        let mut headers = Vec::new();
        while !headers.ends_with(b"\r\n\r\n") {
            if headers.len() >= MAXIMUM_HEADER_BYTES {
                return Err("gh fixture headers exceed their bound".into());
            }
            let mut byte = [0];
            socket
                .read_exact(&mut byte)
                .map_err(|error| format!("read gh fixture header: {error}"))?;
            headers.extend(byte);
        }
        let headers = String::from_utf8(headers).map_err(|error| error.to_string())?;
        let length = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("Content-Length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
            .ok_or("gh fixture requires Content-Length")?;
        if length > MAXIMUM_BODY_BYTES {
            return Err("gh fixture body exceeds its bound".into());
        }
        let mut body = vec![0; length];
        socket
            .read_exact(&mut body)
            .map_err(|error| format!("read gh fixture body: {error}"))?;
        let head = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            response.len()
        );
        socket
            .write_all(head.as_bytes())
            .and_then(|()| socket.write_all(&response))
            .map_err(|error| error.to_string())?;
        Ok(Request { headers, body })
    });
    let result = run(&format!("http://{address}"));
    let request = server.join().unwrap().unwrap();
    (result, request)
}

#[test]
fn native_creation_keeps_response_identity_without_another_lookup() {
    let directory = workspace("create");
    let tag = "v0.1.0";
    let created = serde_json::json!({"id":RELEASE_ID,"tag_name":tag,"draft":true,"immutable":false,"published_at":null});
    let notes = serde_json::json!({"tag_name":tag,"draft":true,"body":"Notes with \"quotes\".\nAnother line."});
    let mut discoveries = 0;
    let (result, request) = exchange(
        "201 Created",
        &serde_json::to_vec(&created).unwrap(),
        |host| {
            acquire_draft_from(
                tag,
                || {
                    discoveries += 1;
                    Ok(None)
                },
                || {
                    let mut command = Command::new("gh");
                    command.args([
                        "api",
                        "--method",
                        "POST",
                        &format!("{host}/repos/P4suta/gleam-mutants/releases"),
                    ]);
                    isolate(&mut command, &directory);
                    mutate_command(&mut command, &notes)
                },
            )
        },
    );
    assert_eq!(result.unwrap(), created);
    assert_eq!(discoveries, 1);
    assert!(
        request
            .headers
            .starts_with("POST /repos/P4suta/gleam-mutants/releases HTTP/1.1\r\n")
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&request.body).unwrap(),
        notes
    );
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn native_upload_preserves_the_release_id_binary_bytes_and_query_name() {
    let directory = workspace("upload");
    let name = "package+fixture.bin";
    let bytes = b"binary\0content\r\n";
    fs::write(directory.join(name), bytes).unwrap();
    let artifact = candidate::artifact(&directory, name).unwrap();
    let id = ReleaseId::new(RELEASE_ID).unwrap();
    let uploaded =
        serde_json::json!({"id":RELEASE_ID,"name":name,"size":bytes.len(),"state":"uploaded"});
    let (result, request) = exchange(
        "201 Created",
        &serde_json::to_vec(&uploaded).unwrap(),
        |host| {
            let original = upload_command(&directory, id, &artifact);
            let mut command = Command::new(original.get_program());
            for argument in original.get_args() {
                let text = argument.to_string_lossy();
                if let Some(path) = text.strip_prefix(constants::GITHUB_UPLOADS_ORIGIN) {
                    command.arg(format!("{host}{path}"));
                } else {
                    command.arg(argument);
                }
            }
            isolate(&mut command, &directory);
            let result = runner::output(&mut command)?;
            let uploaded: Value =
                serde_json::from_slice(&result.stdout).map_err(|error| error.to_string())?;
            require_uploaded(&uploaded, &artifact)
        },
    );
    result.unwrap();
    assert!(request.headers.starts_with(&format!("POST /repos/P4suta/gleam-mutants/releases/{RELEASE_ID}/assets?name=package%2Bfixture.bin HTTP/1.1\r\n")));
    assert!(
        request
            .headers
            .to_lowercase()
            .contains("content-type: application/octet-stream\r\n")
    );
    assert_eq!(request.body, bytes);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn native_mutation_refuses_a_denial_or_an_invalid_success_response() {
    for (label, status, body, diagnostic) in [
        (
            "denied",
            "403 Forbidden",
            &b"{\"message\":\"fixture denial\"}"[..],
            "did not confirm success",
        ),
        (
            "malformed",
            "201 Created",
            &b"not-json"[..],
            "returned invalid JSON",
        ),
    ] {
        let directory = workspace(label);
        let (result, request) = exchange(status, body, |host| {
            let mut command = Command::new("gh");
            command.args([
                "api",
                "--method",
                "POST",
                &format!("{host}/repos/P4suta/gleam-mutants/releases"),
            ]);
            isolate(&mut command, &directory);
            mutate_command(&mut command, &serde_json::json!({"draft":true}))
        });
        let error = result.unwrap_err();
        assert!(error.contains(diagnostic), "{error}");
        assert!(
            error.contains("inspect remote state before retry"),
            "{error}"
        );
        assert!(request.headers.starts_with("POST "));
        fs::remove_dir_all(directory).unwrap();
    }
}
