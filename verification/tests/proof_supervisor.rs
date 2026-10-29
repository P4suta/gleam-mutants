// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#[path = "../src/supervisor.rs"]
mod supervisor;

use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const PROCESS_LIMIT: Duration = Duration::from_secs(10);
static DIRECTORY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn fixture(mode: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_proof_process_fixture"));
    command.arg(mode);
    command
}

fn directory() -> std::path::PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let sequence = DIRECTORY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "gleam-mutants-supervisor-{}-{nonce}-{sequence}",
        std::process::id()
    ));
    std::fs::create_dir(&path).expect("owned fixture directory");
    path
}

#[test]
fn an_exceeded_deadline_terminates_and_reaps_the_client() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_proof_process_fixture"))
        .arg("block")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("owned child");
    let result = supervisor::wait(&mut child, Duration::ZERO);
    let status = child.try_wait().expect("client status");
    if status.is_none() {
        child.kill().expect("fixture cleanup");
        child.wait().expect("reap fixture");
    }
    assert!(result.is_err_and(|message| message.contains("inconclusive")));
    assert!(
        status.is_some(),
        "the failed monitor left its client running"
    );
}

#[test]
fn completed_processes_preserve_status_without_running_cleanup() {
    let directory = directory();
    for mode in ["success", "failure"] {
        let output = supervisor::run(
            &mut fixture(mode),
            &mut fixture("block"),
            &directory,
            PROCESS_LIMIT,
            Duration::ZERO,
        )
        .expect("completed process");
        assert_eq!(output.status.success(), mode == "success");
    }
    std::fs::remove_dir_all(directory).expect("fixture cleanup");
}

#[test]
fn cleanup_exit_failure_preserves_the_primary_deadline() {
    let directory = directory();
    let error = supervisor::run(
        &mut fixture("block"),
        &mut fixture("failure"),
        &directory,
        Duration::ZERO,
        PROCESS_LIMIT,
    )
    .expect_err("failed cleanup");
    std::fs::remove_dir_all(directory).expect("fixture cleanup");
    assert!(error.contains("process exceeded"));
    assert!(error.contains("cleanup failed ("));
}

#[test]
fn cleanup_has_its_own_deadline() {
    let directory = directory();
    let error = supervisor::run(
        &mut fixture("block"),
        &mut fixture("block"),
        &directory,
        Duration::ZERO,
        Duration::ZERO,
    )
    .expect_err("cleanup deadline");
    std::fs::remove_dir_all(directory).expect("fixture cleanup");
    assert!(error.contains("process exceeded"));
    assert!(error.contains("cleanup failed: inconclusive"));
}

#[test]
fn missing_cleanup_program_preserves_the_primary_deadline() {
    let directory = directory();
    let missing = directory.join("missing-cleanup");
    let error = supervisor::run(
        &mut fixture("block"),
        &mut Command::new(missing),
        &directory,
        Duration::ZERO,
        PROCESS_LIMIT,
    )
    .expect_err("missing cleanup command");
    std::fs::remove_dir_all(directory).expect("fixture cleanup");
    assert!(error.contains("process exceeded"));
    assert!(error.contains("cleanup failed: start process"));
}
