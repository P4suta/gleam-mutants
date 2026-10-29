// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::fs;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const STATUS_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub fn wait(child: &mut Child, timeout: Duration) -> Result<ExitStatus, String> {
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) if started.elapsed() >= timeout => {
                return Err(format!(
                    "inconclusive: process exceeded {}ms; {}",
                    timeout.as_millis(),
                    stop(child)
                ));
            }
            Ok(None) => {
                thread::sleep(STATUS_POLL_INTERVAL.min(timeout.saturating_sub(started.elapsed())))
            }
            Err(error) => {
                return Err(format!(
                    "inconclusive: could not inspect process: {error}; {}",
                    stop(child)
                ));
            }
        }
    }
}

fn stop(child: &mut Child) -> String {
    match child.kill() {
        Ok(()) => match child.wait() {
            Ok(status) => format!("client terminated and reaped ({status})"),
            Err(error) => format!("could not reap terminated client: {error}"),
        },
        Err(error) => match child.try_wait() {
            Ok(Some(status)) => format!("client already exited and reaped ({status})"),
            Ok(None) => format!("could not terminate client: {error}"),
            Err(inspect) => {
                format!("could not terminate client: {error}; could not inspect client: {inspect}")
            }
        },
    }
}

fn capture(
    command: &mut Command,
    directory: &Path,
    label: &str,
    timeout: Duration,
) -> Result<Output, String> {
    let stdout = directory.join(format!("{label}-stdout.log"));
    let stderr = directory.join(format!("{label}-stderr.log"));
    command.stdin(Stdio::null());
    command.stdout(Stdio::from(
        fs::File::create(&stdout).map_err(|e| format!("create stdout capture: {e}"))?,
    ));
    command.stderr(Stdio::from(
        fs::File::create(&stderr).map_err(|e| format!("create stderr capture: {e}"))?,
    ));
    let mut child = command.spawn().map_err(|e| format!("start process: {e}"))?;
    let status = wait(&mut child, timeout)?;
    Ok(Output {
        status,
        stdout: fs::read(stdout).map_err(|e| format!("read stdout capture: {e}"))?,
        stderr: fs::read(stderr).map_err(|e| format!("read stderr capture: {e}"))?,
    })
}

pub fn run(
    command: &mut Command,
    cleanup: &mut Command,
    directory: &Path,
    timeout: Duration,
    cleanup_timeout: Duration,
) -> Result<Output, String> {
    match capture(command, directory, "process", timeout) {
        Ok(output) => Ok(output),
        Err(primary) => {
            let cleanup = match capture(cleanup, directory, "cleanup", cleanup_timeout) {
                Ok(output) if output.status.success() => "cleanup completed".to_owned(),
                Ok(output) => format!(
                    "cleanup failed ({}): {}{}",
                    output.status,
                    String::from_utf8_lossy(&output.stdout),
                    String::from_utf8_lossy(&output.stderr)
                ),
                Err(error) => format!("cleanup failed: {error}"),
            };
            Err(format!("{primary}; {cleanup}"))
        }
    }
}
