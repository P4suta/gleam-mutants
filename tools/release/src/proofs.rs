// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::{candidate, runner, supervisor};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const SOURCE: &str = "tools/release-core/src/lib.rs";
const DEADLINE: Duration = Duration::from_secs(900);
const CLEANUP_DEADLINE: Duration = Duration::from_secs(10);
const RESOURCE_KILL: i32 = 137;
const VERSION: &str = "Kani Rust Verifier 0.68.0";
const POSITIVE_SUMMARY: &str = "3 successfully verified harnesses, 0 failures, 3 total";
const NEGATIVE_SUMMARY: &str = "0 successfully verified harnesses, 1 failures, 1 total";

fn counterexample(success: bool, diagnostics: &str, harness: &str) -> bool {
    let failure = format!("Verification failed for - proofs::{harness}");
    !success
        && diagnostics.contains("VERIFICATION:- FAILED")
        && diagnostics.contains(NEGATIVE_SUMMARY)
        && diagnostics.lines().any(|line| line == failure)
}

fn text(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn check(image: &str, directory: &Path, label: &str, args: &[&str]) -> Result<Output, String> {
    let name = format!("gleam-mutants-release-proof-{}-{label}", std::process::id());
    let mut command = Command::new("docker");
    command
        .args([
            "run",
            "--rm",
            "--platform",
            "linux/amd64",
            "--name",
            &name,
            "--network",
            "none",
            "--memory",
            "2g",
            "--memory-swap",
            "2g",
            "--cpus",
            "2",
            "--pids-limit",
            "256",
            "--mount",
            &format!("type=bind,src={},dst=/proof", directory.display()),
            "--workdir",
            "/proof",
            image,
        ])
        .args(args);
    let mut cleanup = Command::new("docker");
    cleanup.args(["rm", "--force", &name]);
    let output = supervisor::run(
        &mut command,
        &mut cleanup,
        directory,
        DEADLINE,
        CLEANUP_DEADLINE,
    )?;
    if output.status.code() == Some(RESOURCE_KILL) {
        return Err("inconclusive: release proof reached a container resource limit".into());
    }
    Ok(output)
}

pub fn prove() -> Result<(), String> {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let directory = PathBuf::from(format!(
        "build/release-proofs/{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let directory = directory.canonicalize().map_err(|e| e.to_string())?;
    let image_file = directory.join("image-id");
    runner::output(
        Command::new("docker")
            .args(["build", "--platform", "linux/amd64", "--iidfile"])
            .arg(&image_file)
            .arg("tools/release-core"),
    )?;
    let image = fs::read_to_string(image_file).map_err(|e| e.to_string())?;
    let source = fs::read_to_string(SOURCE).map_err(|e| e.to_string())?;
    let positive = directory.join("positive");
    fs::create_dir(&positive).map_err(|e| e.to_string())?;
    fs::write(positive.join("lib.rs"), &source).map_err(|e| e.to_string())?;
    let version = check(image.trim(), &positive, "version", &["kani", "--version"])?;
    if !version.status.success() || !text(&version).contains(VERSION) {
        return Err("unexpected release proof verifier".into());
    }
    let args = [
        "kani",
        "lib.rs",
        "--target-dir",
        "/proof/output",
        "--output-format",
        "terse",
    ];
    let result = check(image.trim(), &positive, "positive", &args)?;
    fs::write(positive.join("result.log"), text(&result)).map_err(|e| e.to_string())?;
    if !result.status.success() || !text(&result).contains(POSITIVE_SUMMARY) {
        return Err(format!(
            "release policy proof is incomplete:\n{}",
            text(&result)
        ));
    }
    let controls = [
        (
            "runtime",
            "m.total != 0",
            "m.total == 0",
            "runtime_counts_exclude_empty_and_inconclusive_measurements",
        ),
        (
            "finalization",
            "identity && assets && hex && npm && draft",
            "identity || assets || hex || npm || draft",
            "finalization_requires_every_obligation",
        ),
        (
            "reuse",
            "(true, Existing::Missing) => WritePlan::Create,",
            "(true, Existing::Missing) => WritePlan::Reuse,",
            "writes_preserve_verified_outputs",
        ),
    ];
    for (label, original, broken, harness) in controls {
        if source.matches(original).count() != 1 {
            return Err(format!(
                "proof control no longer identifies one production expression: {label}"
            ));
        }
        let negative = directory.join(label);
        fs::create_dir(&negative).map_err(|e| e.to_string())?;
        fs::write(
            negative.join("lib.rs"),
            source.replacen(original, broken, 1),
        )
        .map_err(|e| e.to_string())?;
        let selected = format!("proofs::{harness}");
        let mut control_args = args.to_vec();
        control_args.extend(["--harness", &selected]);
        let result = check(image.trim(), &negative, label, &control_args)?;
        let diagnostics = text(&result);
        fs::write(negative.join("result.log"), &diagnostics).map_err(|e| e.to_string())?;
        if !counterexample(result.status.success(), &diagnostics, harness) {
            return Err(format!(
                "proof control {label} supplied no expected counterexample:\n{diagnostics}"
            ));
        }
    }
    println!(
        "Source-bound Kani policy proofs passed with three rejected broken implementations; source SHA256 {}",
        candidate::digest(source.as_bytes())
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::counterexample;

    #[test]
    fn another_failed_harness_or_a_tool_error_cannot_supply_the_control() {
        let wanted = "runtime_counts_exclude_empty_and_inconclusive_measurements";
        let genuine = format!(
            "VERIFICATION:- FAILED\nVerification failed for - proofs::{wanted}\nComplete - 0 successfully verified harnesses, 1 failures, 1 total.\n"
        );
        assert!(counterexample(false, &genuine, wanted));
        assert!(!counterexample(true, &genuine, wanted));
        let another = format!(
            "Checking harness proofs::{wanted}...\nVERIFICATION:- FAILED\nVerification failed for - proofs::another\nComplete - 0 successfully verified harnesses, 1 failures, 1 total.\n"
        );
        assert!(!counterexample(false, &another, wanted));
        assert!(!counterexample(
            false,
            &format!("failed to compile {wanted}"),
            wanted
        ));
        assert!(!counterexample(
            false,
            &genuine.replace("1 failures, 1 total", "2 failures, 3 total"),
            wanted
        ));
    }
}
