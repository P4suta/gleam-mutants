// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn compiler_interruption_returns_to_the_api_on_every_runtime() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("repository");
    let gleam = Command::new("mise")
        .args(["which", "gleam"])
        .current_dir(root)
        .output()
        .expect("pinned Gleam");
    assert!(gleam.status.success());
    let gleam = String::from_utf8(gleam.stdout)
        .expect("Gleam path")
        .trim()
        .to_owned();
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let directory = std::env::temp_dir().join(format!(
        "gleam-mutants-compiler-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir(&directory).expect("owned fixture directory");
    fs::copy(
        env!("CARGO_BIN_EXE_compiler_exit_fixture"),
        directory.join(if cfg!(windows) { "gleam.exe" } else { "gleam" }),
    )
    .expect("fixture compiler");
    let mut paths = vec![directory.clone()];
    paths.extend(std::env::split_paths(
        &std::env::var_os("PATH").expect("tool path"),
    ));
    let path = std::env::join_paths(paths).expect("fixture path");
    let mut failure = None;
    for code in [130, 143] {
        for (target, runtime) in [
            ("erlang", "erlang"),
            ("javascript", "node"),
            ("javascript", "deno"),
            ("javascript", "bun"),
        ] {
            let mut command = Command::new(&gleam);
            command.args([
                "run",
                "-m",
                "library_compiler_interrupt_smoke",
                "--target",
                target,
            ]);
            if target == "javascript" {
                command.args(["--runtime", runtime]);
            }
            let result = command
                .current_dir(root)
                .env("PATH", &path)
                .env("GLEAM_MUTANTS_INTERRUPT_CODE", code.to_string())
                .output()
                .expect("API host");
            let stdout = String::from_utf8_lossy(&result.stdout);
            if !result.status.success()
                || !stdout.contains(&format!("API compiler host continued after {code}"))
            {
                failure = Some(format!(
                    "{runtime} compiler exit {code}: {}\n{stdout}\n{}",
                    result.status,
                    String::from_utf8_lossy(&result.stderr)
                ));
                break;
            }
            println!("{runtime}: compiler exit {code} returned to the API");
        }
        if failure.is_some() {
            break;
        }
    }
    fs::remove_dir_all(directory).expect("fixture cleanup");
    assert!(failure.is_none(), "{}", failure.unwrap_or_default());
}
