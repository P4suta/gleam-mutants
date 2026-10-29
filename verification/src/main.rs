// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

mod filesystem_entry;
mod limits;
mod supervisor;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const SOURCE: &str = "src/gleam_mutants/core/limits.gleam";
const ENTRY_SOURCE: &str = "src/gleam_mutants/core/filesystem_entry.gleam";
const CONTRACT_SOURCE: &str = "verification/Contracts.lean";
struct Contract {
    theorem: &'static str,
    predicate: &'static str,
    original: &'static str,
    broken: &'static str,
    source: &'static str,
}
const CONTRACTS: [Contract; 6] = [
    Contract {
        theorem: "jobs_contract",
        predicate: "valid_jobs",
        original: "maximum_jobs = 32",
        broken: "maximum_jobs = 33",
        source: SOURCE,
    },
    Contract {
        theorem: "timeout_contract",
        predicate: "valid_timeout",
        original: "minimum_timeout_ms = 100",
        broken: "minimum_timeout_ms = 101",
        source: SOURCE,
    },
    Contract {
        theorem: "interruption_contract",
        predicate: "interrupted",
        original: "interrupt_exit_code = 130",
        broken: "interrupt_exit_code = 131",
        source: SOURCE,
    },
    Contract {
        theorem: "unshared_file_contract",
        predicate: "unshared_file",
        original: "unshared_file_link_count = 1",
        broken: "unshared_file_link_count = 2",
        source: SOURCE,
    },
    Contract {
        theorem: "compiler_rejection_contract",
        predicate: "compiler_rejected",
        original: "compiler_rejection_exit_code = 1",
        broken: "compiler_rejection_exit_code = 2",
        source: SOURCE,
    },
    Contract {
        theorem: "filesystem_entry_contract",
        predicate: "valid",
        original: "value != \"..\"",
        broken: "value != \".\"",
        source: ENTRY_SOURCE,
    },
];
const PROOF_TIMEOUT: Duration = Duration::from_secs(900);
const CONTAINER_CLEANUP_TIMEOUT: Duration = Duration::from_secs(10);
const CONTAINER_KILLED_EXIT_CODE: i32 = 137;
static CONTAINER_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn read(path: impl AsRef<Path>) -> Result<String, String> {
    fs::read_to_string(path.as_ref())
        .map_err(|error| format!("{}: {error}", path.as_ref().display()))
}

fn write(path: impl AsRef<Path>, contents: &str) -> Result<(), String> {
    fs::write(path.as_ref(), contents)
        .map_err(|error| format!("{}: {error}", path.as_ref().display()))
}

fn text(result: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    )
}

fn model(directory: &Path, source: &str, entry: &str, contracts: &str) -> Result<(), String> {
    fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    let derived = limits::derive(source)? + &filesystem_entry::derive(entry)?;
    write(directory.join("Derived.lean"), &derived)?;
    write(directory.join("source.gleam"), source)?;
    write(directory.join("filesystem_entry.gleam"), entry)?;
    write(directory.join("Contracts.lean"), contracts)
}

fn bounded(image: &str, directory: &Path, args: &[&str]) -> Result<Output, String> {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let sequence = CONTAINER_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let name = format!(
        "gleam-mutants-proof-{}-{nonce}-{sequence}",
        std::process::id()
    );
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
            "--env",
            "LEAN_PATH=/proof",
            "--workdir",
            "/proof",
            "--mount",
            &format!("type=bind,src={},dst=/proof", directory.display()),
            image,
        ])
        .args(args);
    let mut cleanup = Command::new("docker");
    cleanup.args(["rm", "--force", &name]);
    let result = supervisor::run(
        &mut command,
        &mut cleanup,
        directory,
        PROOF_TIMEOUT,
        CONTAINER_CLEANUP_TIMEOUT,
    )?;
    if result.status.code() == Some(CONTAINER_KILLED_EXIT_CODE) {
        return Err(
            "inconclusive: proof container was killed, possibly at its resource limit".into(),
        );
    }
    Ok(result)
}

fn checked(image: &str, directory: &Path, args: &[&str]) -> Result<Output, String> {
    let result = bounded(image, directory, args)?;
    if !result.status.success() {
        return Err(format!(
            "proof command {args:?} failed ({}):\n{}",
            result.status,
            text(&result)
        ));
    }
    Ok(result)
}

fn prove() -> Result<(), String> {
    let source = read(SOURCE)?;
    let entry = read(ENTRY_SOURCE)?;
    let contracts = read(CONTRACT_SOURCE)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let directory = PathBuf::from(format!("build/verification/{}-{nonce}", std::process::id()));
    fs::create_dir_all("build/verification").map_err(|error| error.to_string())?;
    fs::create_dir(&directory).map_err(|error| error.to_string())?;
    let directory = directory
        .canonicalize()
        .map_err(|error| error.to_string())?;
    let image_file = directory.join("image-id");
    println!("Building the pinned Lean 4.34.1 proof environment");
    let built = Command::new("docker")
        .args(["build", "--platform", "linux/amd64", "--iidfile"])
        .arg(&image_file)
        .arg("verification")
        .output()
        .map_err(|e| e.to_string())?;
    if !built.status.success() {
        return Err(format!("proof image build failed:\n{}", text(&built)));
    }
    let image = read(image_file)?;
    let image = image.trim();
    let positive = directory.join("positive");
    model(&positive, &source, &entry, &contracts)?;
    let version = checked(image, &positive, &["lean", "--version"])?;
    if !text(&version).contains("Lean (version 4.34.1,") {
        return Err(format!("unexpected verifier version: {}", text(&version)));
    }
    checked(
        image,
        &positive,
        &["lean", "-o", "Derived.olean", "Derived.lean"],
    )?;
    let proof = checked(
        image,
        &positive,
        &["lean", "-o", "Contracts.olean", "Contracts.lean"],
    )?;
    let axioms = text(&proof);
    for contract in &CONTRACTS {
        let theorem = contract.theorem;
        if !axioms.contains(&format!("'{theorem}' does not depend on any axioms")) {
            return Err(format!("missing axiom-free theorem {theorem}:\n{axioms}"));
        }
    }
    write(positive.join("axioms.log"), &axioms)?;
    let replay = checked(
        image,
        &positive,
        &["leanchecker", "--fresh", "--verbose", "Contracts"],
    )?;
    if !text(&replay).contains("replaying Contracts with --fresh") {
        return Err(format!("missing fresh-kernel replay: {}", text(&replay)));
    }
    write(positive.join("replay.log"), &text(&replay))?;
    for contract in &CONTRACTS {
        let original = match contract.source {
            SOURCE => &source,
            ENTRY_SOURCE => &entry,
            other => return Err(format!("unknown contract source {other}")),
        };
        let broken = original.replace(contract.original, contract.broken);
        if broken == *original {
            return Err(format!(
                "negative control could not change {}",
                contract.predicate
            ));
        }
        let negative = directory.join(contract.predicate);
        match contract.source {
            SOURCE => model(&negative, &broken, &entry, &contracts)?,
            ENTRY_SOURCE => model(&negative, &source, &broken, &contracts)?,
            other => return Err(format!("unknown contract source {other}")),
        }
        checked(
            image,
            &negative,
            &["lean", "-o", "Derived.olean", "Derived.lean"],
        )?;
        let refused = bounded(
            image,
            &negative,
            &["lean", "-o", "Contracts.olean", "Contracts.lean"],
        )?;
        let diagnostic = text(&refused);
        if refused.status.success()
            || !diagnostic.contains("Tactic `rfl` failed")
            || !diagnostic.contains(&format!("Derived.{} value", contract.predicate))
            || !diagnostic.contains("error:")
        {
            return Err(format!(
                "negative control for {} did not produce the expected failed equality proof:\n{diagnostic}",
                contract.predicate
            ));
        }
        write(negative.join("refusal.log"), &diagnostic)?;
    }
    if read(SOURCE)? != source
        || read(ENTRY_SOURCE)? != entry
        || read(CONTRACT_SOURCE)? != contracts
    {
        return Err("production source or contracts changed during verification".into());
    }
    println!(
        "{} source-derived contracts passed without axioms; fresh-kernel replay and all {} negative controls passed",
        CONTRACTS.len(),
        CONTRACTS.len()
    );
    println!("Evidence: {}", directory.display());
    Ok(())
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [command] if command == "prove" => prove(),
        [command, directory] if command == "derive" => model(
            Path::new(directory),
            &read(SOURCE)?,
            &read(ENTRY_SOURCE)?,
            &read(CONTRACT_SOURCE)?,
        ),
        [] => {
            println!(
                "usage: gleam-mutants-verification derive OUTPUT_DIRECTORY | prove\nRun from the repository root; prove needs Docker and uses offline 2-CPU, 2-GiB containers."
            );
            Ok(())
        }
        [flag] if flag == "--help" => {
            println!("usage: gleam-mutants-verification derive OUTPUT_DIRECTORY | prove");
            Ok(())
        }
        _ => Err("usage: gleam-mutants-verification derive OUTPUT_DIRECTORY | prove".into()),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
