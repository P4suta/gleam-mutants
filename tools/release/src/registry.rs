// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::candidate::{self, Version};
use crate::constants;
use gleam_mutants_release_core::Existing;
use serde_json::Value;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

const HTTP_SUCCESS: u16 = 200;
const HTTP_CREATED: u16 = 201;
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_DEADLINE_SECONDS: &str = "60";
const MAXIMUM_RESPONSE_BYTES: usize = 256 * 1024 * 1024;

pub enum Registry {
    Hex,
    Npm,
}

enum Request<'a> {
    Get,
    AuthenticatedGet(&'a str),
    Publish(&'a Path, &'a str),
}

impl Registry {
    fn metadata(&self, version: &Version) -> String {
        match self {
            Self::Hex => format!(
                "{}/packages/gleam_mutants/releases/{}",
                constants::HEX_API,
                version.as_str()
            ),
            Self::Npm => format!(
                "{}/gleam-mutants/{}",
                constants::NPM_REGISTRY,
                version.as_str()
            ),
        }
    }
    fn archive(&self, version: &Version) -> String {
        match self {
            Self::Hex => format!(
                "{}/gleam_mutants-{}.tar",
                constants::HEX_ARCHIVES,
                version.as_str()
            ),
            Self::Npm => format!(
                "{}/gleam-mutants/-/gleam-mutants-{}.tgz",
                constants::NPM_REGISTRY,
                version.as_str()
            ),
        }
    }
}

struct Response {
    status: u16,
    body: Vec<u8>,
}

fn request(url: &str, request: Request<'_>) -> Result<Response, String> {
    let (upload, key) = match request {
        Request::Get => (None, None),
        Request::AuthenticatedGet(key) => (None, Some(key)),
        Request::Publish(path, key) => (Some(path), Some(key)),
    };
    let mut command = Command::new("curl");
    command.args([
        "--silent",
        "--show-error",
        "--proto",
        "=https",
        "--max-time",
        HTTP_DEADLINE_SECONDS,
        "--max-filesize",
        &MAXIMUM_RESPONSE_BYTES.to_string(),
        "--user-agent",
        "gleam-mutants-release/0.0.0",
        "--write-out",
        "\n%{http_code}",
    ]);
    if let Some(path) = upload {
        command
            .args(["--request", "POST", "--data-binary"])
            .arg(format!("@{}", path.display()));
    } else {
        command.args(["--request", "GET"]);
    }
    command.args(if key.is_some() {
        ["--header", "@-"]
    } else {
        ["--header", "Accept: application/json"]
    });
    command
        .arg(url)
        .stdin(if key.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|e| format!("registry transport: {e}"))?;
    if let Some(key) = key {
        let header = format!(
            "Authorization: {key}\nAccept: application/json\nContent-Type: application/octet-stream\n"
        );
        let written = match child.stdin.take() {
            Some(mut stdin) => stdin.write_all(header.as_bytes()),
            None => Err(std::io::Error::other(
                "registry transport has no credential input",
            )),
        };
        if let Err(error) = written {
            let primary = format!("registry credential transport failed: {error}");
            let killed = child.kill();
            let reaped = child.wait();
            return Err(format!(
                "{primary}; cleanup kill={killed:?}, wait={reaped:?}"
            ));
        }
    }
    let output = child
        .wait_with_output()
        .map_err(|e| format!("registry transport completion: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "registry transport incomplete: {}; inspect the registry before another write",
            output.status
        ));
    }
    let split = output
        .stdout
        .iter()
        .rposition(|byte| *byte == b'\n')
        .ok_or("registry transport omitted its status")?;
    let (body, status) = output.stdout.split_at(split);
    if body.len() > MAXIMUM_RESPONSE_BYTES {
        return Err("registry response exceeds its admitted size".into());
    }
    let status: u16 = std::str::from_utf8(status)
        .map_err(|e| e.to_string())?
        .trim()
        .parse()
        .map_err(|_| "invalid registry status")?;
    Ok(Response {
        status,
        body: body.to_vec(),
    })
}

pub fn observe(
    registry: Registry,
    version: &Version,
    expected_digest: &str,
) -> Result<Existing, String> {
    let response = request(&registry.metadata(version), Request::Get)?;
    if response.status == HTTP_NOT_FOUND {
        return Ok(Existing::Missing);
    }
    if response.status != HTTP_SUCCESS {
        return Err(format!(
            "registry metadata read refused with HTTP {}",
            response.status
        ));
    }
    let metadata: Value =
        serde_json::from_slice(&response.body).map_err(|e| format!("registry metadata: {e}"))?;
    if metadata["version"] != version.as_str() {
        return Err("registry version identity mismatch".into());
    }
    let response = request(&registry.archive(version), Request::Get)?;
    if response.status != HTTP_SUCCESS {
        return Err(format!(
            "registry archive read refused with HTTP {}",
            response.status
        ));
    }
    if candidate::digest(&response.body) == expected_digest {
        Ok(Existing::Matching)
    } else {
        Ok(Existing::Conflicting)
    }
}

pub fn publish_hex(path: &Path, key: &str) -> Result<(), String> {
    validate_key(key)?;
    let response = request(
        &format!("{}/publish", constants::HEX_API),
        Request::Publish(path, key),
    )?;
    if response.status != HTTP_CREATED {
        return Err(format!(
            "Hex publication did not confirm creation: HTTP {}; inspect remote state before retry",
            response.status
        ));
    }
    Ok(())
}

pub fn validate_key(key: &str) -> Result<(), String> {
    if key.is_empty() || !key.bytes().all(|byte| byte.is_ascii_graphic()) || key.starts_with("${") {
        return Err("publishing key is missing, unresolved, or malformed".into());
    }
    Ok(())
}

pub fn verify_identity(registry: Registry, username: &str, key: &str) -> Result<(), String> {
    validate_key(key)?;
    if username.is_empty() || username.contains(['\r', '\n']) {
        return Err("expected registry username is missing or malformed".into());
    }
    let (url, authorization) = match registry {
        Registry::Hex => (format!("{}/users/me", constants::HEX_API), key.to_owned()),
        Registry::Npm => (
            format!("{}/-/whoami", constants::NPM_REGISTRY),
            format!("Bearer {key}"),
        ),
    };
    let response = request(&url, Request::AuthenticatedGet(&authorization))?;
    if response.status != HTTP_SUCCESS {
        return Err(format!(
            "registry identity read refused with HTTP {}; authentication or metadata permission remains unverified",
            response.status
        ));
    }
    let metadata: Value = serde_json::from_slice(&response.body)
        .map_err(|_| "registry identity response is malformed")?;
    if metadata["username"] != username {
        return Err("registry identity differs from the expected account".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate_key;

    #[test]
    fn rejects_missing_unresolved_and_header_injection_inputs() {
        for value in [
            "",
            "${project.config.KEY}",
            "value\r\nOther: header",
            "two values",
        ] {
            assert!(validate_key(value).is_err());
        }
        assert!(validate_key("fixture-key").is_ok());
    }
}
