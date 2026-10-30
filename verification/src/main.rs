// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

mod bridge;
mod configuration;
mod contracts;
mod filesystem_entry;
mod limits;
mod supervisor;

use gleam_mutants_verification::{fragment, outcome, paths, scoring, selection, span};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const SOURCE: &str = "src/gleam_mutants/core/limits.gleam";
const ENTRY_SOURCE: &str = "src/gleam_mutants/core/filesystem_entry.gleam";
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

#[derive(Clone)]
struct Snapshot {
    sources: BTreeMap<&'static str, String>,
    proofs: BTreeMap<String, String>,
}

impl Snapshot {
    fn read() -> Result<Self, String> {
        configuration::check()?;
        Ok(Self {
            sources: contracts::SOURCES
                .iter()
                .map(|path| Ok((*path, read(path)?)))
                .collect::<Result<_, String>>()?,
            proofs: contracts::SUITES
                .iter()
                .map(|suite| {
                    let path = format!("verification/{}.lean", suite.module);
                    Ok((path.clone(), read(path)?))
                })
                .collect::<Result<_, String>>()?,
        })
    }

    fn source(&self, name: &str) -> Result<&str, String> {
        self.sources
            .iter()
            .find(|(path, _)| Path::new(path).file_name().is_some_and(|file| file == name))
            .map(|(_, text)| text.as_str())
            .ok_or_else(|| format!("missing source {name}"))
    }

    fn changed(&self, name: &str, original: &str, broken: &str) -> Result<Self, String> {
        let mut changed = self.clone();
        let source = changed
            .sources
            .iter_mut()
            .find(|(path, _)| {
                **path == name || Path::new(path).file_name().is_some_and(|file| file == name)
            })
            .map(|(_, text)| text)
            .ok_or_else(|| format!("unknown control source {name}"))?;
        if source.matches(original).count() != 1 {
            return Err(format!(
                "control must change exactly one source fragment: {name}: {original:?}"
            ));
        }
        *source = source.replacen(original, broken, 1);
        Ok(changed)
    }
}

fn model(directory: &Path, snapshot: &Snapshot) -> Result<(), String> {
    fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    configuration::copy(directory)?;
    fragment::validate_types(snapshot.source("types.gleam")?)?;
    let derived = limits::derive(snapshot.source("limits.gleam")?)?
        + &filesystem_entry::derive(snapshot.source("filesystem_entry.gleam")?)?
        + &span::derive(snapshot.source("span.gleam")?)?
        + &outcome::derive(snapshot.source("outcome.gleam")?)?;
    let derived = derived
        + &scoring::derive_score(snapshot.source("score.gleam")?)?
        + &scoring::derive_policy(snapshot.source("exit_policy.gleam")?)?;
    let derived = derived
        + &selection::derive_operator(snapshot.source("operator.gleam")?)?
        + &selection::derive_plan(snapshot.source("plan.gleam")?)?;
    let derived = "import Lean.Elab.Tactic.Omega\n".to_owned()
        + &derived
        + &paths::derive_path(snapshot.source("path.gleam")?)?
        + &paths::derive_glob(snapshot.source("glob.gleam")?)?;
    write(directory.join("Derived.lean"), &derived)?;
    for (path, source) in snapshot
        .sources
        .iter()
        .map(|(path, source)| (*path, source))
        .chain(
            snapshot
                .proofs
                .iter()
                .map(|(path, source)| (path.as_str(), source)),
        )
    {
        write(
            directory.join(
                Path::new(path)
                    .file_name()
                    .ok_or("source has no filename")?,
            ),
            source,
        )?;
    }
    Ok(())
}

fn bounded(image: &str, directory: &Path, args: &[&str]) -> Result<Output, String> {
    configuration::check()?;
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
    let snapshot = Snapshot::read()?;
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
    println!("Evidence: {}", directory.display());
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
    model(&positive, &snapshot)?;
    let version = checked(image, &positive, &["lean", "--version"])?;
    if !text(&version).contains("Lean (version 4.34.1,") {
        return Err(format!("unexpected verifier version: {}", text(&version)));
    }
    checked(
        image,
        &positive,
        &["lean", "-o", "Derived.olean", "Derived.lean"],
    )?;
    for suite in contracts::SUITES {
        let proof = checked(
            image,
            &positive,
            &[
                "lean",
                "-o",
                &format!("{}.olean", suite.module),
                &format!("{}.lean", suite.module),
            ],
        )?;
        let axioms = text(&proof);
        contracts::check_axioms(suite, &axioms)?;
        write(
            positive.join(format!("{}-axioms.log", suite.module)),
            &axioms,
        )?;
        println!(
            "{}: {} named theorems and axiom inventories passed",
            suite.module,
            suite.theorems.len()
        );
    }
    let imports: String = contracts::SUITES
        .iter()
        .map(|suite| format!("import {}\n", suite.module))
        .collect();
    write(positive.join("AllContracts.lean"), &imports)?;
    checked(
        image,
        &positive,
        &["lean", "-o", "AllContracts.olean", "AllContracts.lean"],
    )?;
    let replay = checked(
        image,
        &positive,
        &["leanchecker", "--fresh", "--verbose", "AllContracts"],
    )?;
    if !text(&replay).contains("replaying AllContracts with --fresh") {
        return Err(format!("missing fresh-kernel replay: {}", text(&replay)));
    }
    write(positive.join("replay.log"), &text(&replay))?;
    write(positive.join("Bridge.lean"), include_str!("../Bridge.lean"))?;
    let reference = checked(image, &positive, &["lean", "--run", "Bridge.lean"])?;
    let reference = text(&reference);
    bridge::records(&reference)?;
    write(positive.join("bridge-model.log"), &reference)?;
    for (target, runtime) in [
        ("erlang", "erlang"),
        ("javascript", "node"),
        ("javascript", "deno"),
        ("javascript", "bun"),
    ] {
        let mut command = Command::new("gleam");
        command.args(["run", "-m", "proof_model_smoke", "--target", target]);
        if target == "javascript" {
            command.args(["--runtime", runtime]);
        }
        let result = command
            .output()
            .map_err(|error| format!("native bridge {runtime}: {error}"))?;
        let actual = text(&result);
        if !result.status.success() {
            return Err(format!("native bridge {runtime} failed: {actual}"));
        }
        bridge::compare(&reference, &actual).map_err(|error| format!("{runtime}: {error}"))?;
        write(positive.join(format!("bridge-{runtime}.log")), &actual)?;
        println!(
            "{runtime}: {} source-model records match production",
            bridge::records(&actual)?.len()
        );
    }
    for contract in &CONTRACTS {
        let broken = snapshot.changed(contract.source, contract.original, contract.broken)?;
        let negative = directory.join(contract.predicate);
        model(&negative, &broken)?;
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
                "negative control for {} did not produce the expected failed equality proof for {}:\n{diagnostic}",
                contract.predicate, contract.theorem
            ));
        }
        write(negative.join("refusal.log"), &diagnostic)?;
    }
    for control in contracts::CONTROLS {
        let proof = if control.source == "glob.gleam" {
            "simp [GlobDerived.accepts, GlobDerived.afterDirectory, GlobDerived.included] <;> rfl"
        } else {
            "rfl"
        };
        let witness = format!(
            "import Derived\ntheorem {} : {} := by {proof}\n",
            control.name, control.claim
        );
        write(positive.join("Control.lean"), &witness)?;
        checked(image, &positive, &["lean", "Control.lean"])?;
        let negative = directory.join(control.name);
        model(
            &negative,
            &snapshot.changed(control.source, control.original, control.broken)?,
        )?;
        write(negative.join("Control.lean"), &witness)?;
        checked(
            image,
            &negative,
            &["lean", "-o", "Derived.olean", "Derived.lean"],
        )?;
        let result = bounded(image, &negative, &["lean", "Control.lean"])?;
        let diagnostic = text(&result);
        if result.status.success()
            || !diagnostic.contains("Tactic `rfl` failed")
            || !diagnostic.contains("error:")
        {
            return Err(format!(
                "{} did not reject the changed implementation with its equality failure:\n{diagnostic}",
                control.name
            ));
        }
        write(negative.join("refusal.log"), &diagnostic)?;
    }
    for (path, source) in snapshot
        .sources
        .iter()
        .map(|(path, source)| (*path, source))
        .chain(
            snapshot
                .proofs
                .iter()
                .map(|(path, source)| (path.as_str(), source)),
        )
    {
        if read(path)? != *source {
            return Err(format!("source changed during verification: {path}"));
        }
    }
    configuration::check()?;
    println!(
        "{} source-derived contracts passed with checked axiom inventories and fresh-kernel replay; all {} negative controls passed",
        contracts::SUITES
            .iter()
            .map(|suite| suite.theorems.len())
            .sum::<usize>(),
        CONTRACTS.len() + contracts::CONTROLS.len()
    );
    Ok(())
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [command] if command == "prove" => prove(),
        [command, directory] if command == "derive" => {
            model(Path::new(directory), &Snapshot::read()?)
        }
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
