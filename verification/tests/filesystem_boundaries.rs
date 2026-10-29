// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const BARRIER_TIMEOUT: Duration = Duration::from_secs(10);
const BARRIER_POLL: Duration = Duration::from_millis(10);

const SHARED_DIRECTORY_FIXTURE: &str = r#"
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const [modulePath, directory, role, ready, release] = process.argv.slice(1);
const timeoutMilliseconds = 10000;
if (role === 'creator') {
  const mkdir = fs.mkdirSync;
  fs.mkdirSync = function(target, ...options) {
    const result = mkdir.call(this, target, ...options);
    if (path.resolve(target) === path.resolve(directory)) {
      fs.writeFileSync(ready, 'ready');
      const deadline = Date.now() + timeoutMilliseconds;
      while (!fs.existsSync(release)) {
        if (Date.now() >= deadline) throw new Error('creation barrier timed out');
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      }
    }
    return result;
  };
}
import(pathToFileURL(modulePath).href).then(({ ensure_private_directory }) => {
  const result = ensure_private_directory(directory);
  if (!result.isOk()) throw new Error(JSON.stringify(result));
  if (role === 'participant') {
    fs.mkdirSync(path.join(directory, 'workspace'));
    fs.writeFileSync(path.join(directory, 'workspace', 'marker'), 'preserved');
  }
}).catch(error => { console.error(error); process.exitCode = 1; });
"#;

const PERMISSIVE_UMASK_ADAPTER: &str = r#"
const { spawnSync } = require('node:child_process');
const timeoutMilliseconds = 120000;
process.umask(0);
const result = spawnSync(process.argv[1], process.argv.slice(2), {
  stdio: 'inherit', shell: false, timeout: timeoutMilliseconds,
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
"#;

#[test]
fn filesystem_boundaries_hold_with_a_permissive_umask_on_all_runtimes() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("repository root");
    for (target, runtime) in [
        ("erlang", None),
        ("javascript", Some("node")),
        ("javascript", Some("deno")),
        ("javascript", Some("bun")),
    ] {
        let mut command = Command::new("node");
        command
            .current_dir(root)
            .args(["-e", PERMISSIVE_UMASK_ADAPTER, "gleam"])
            .args(["run", "-m", "filesystem_boundary_test", "--target", target]);
        if let Some(runtime) = runtime {
            command.args(["--runtime", runtime]);
        }
        let output = command.output().expect("run filesystem boundary fixture");
        assert!(
            output.status.success(),
            "filesystem boundaries failed on {target}/{runtime:?}:\n{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    concurrent_shared_directory_creation_preserves_another_participant(root);
}

fn concurrent_shared_directory_creation_preserves_another_participant(root: &Path) {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock after epoch")
        .as_nanos();
    let fixture = std::env::temp_dir().join(format!(
        "gleam-mutants-shared-directory-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir(&fixture).expect("exclusive fixture root");
    let directory = fixture.join("shared");
    let ready = fixture.join("ready");
    let release = fixture.join("release");
    let module = root.join("build/dev/javascript/gleam_mutants/gleam_mutants/platform.mjs");
    let command = |role: &str| {
        let mut command = Command::new("node");
        command
            .args(["-e", SHARED_DIRECTORY_FIXTURE])
            .arg(&module)
            .arg(&directory)
            .arg(role)
            .arg(&ready)
            .arg(&release);
        command
    };
    let mut creator = command("creator")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start directory creator");
    let started = Instant::now();
    while !ready.exists() && started.elapsed() < BARRIER_TIMEOUT {
        std::thread::sleep(BARRIER_POLL);
    }
    if !ready.exists() {
        creator.kill().expect("stop creator after barrier timeout");
        let output = creator.wait_with_output().expect("reap directory creator");
        panic!(
            "creation barrier did not open: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let participant = command("participant").output().expect("run participant");
    std::fs::write(&release, "release").expect("release creation barrier");
    let creator = creator.wait_with_output().expect("reap directory creator");
    let marker = std::fs::read_to_string(directory.join("workspace/marker"));
    std::fs::remove_dir_all(&fixture).expect("remove shared-directory fixture");
    assert!(
        participant.status.success(),
        "participant failed: {}",
        String::from_utf8_lossy(&participant.stderr)
    );
    assert!(
        creator.status.success(),
        "creator failed: {}",
        String::from_utf8_lossy(&creator.stderr)
    );
    assert_eq!(marker.expect("participant marker remains"), "preserved");
}
