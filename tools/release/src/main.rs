// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use gleam_mutants_release::{candidate, evidence, github, proofs, runner};
use std::path::Path;
use std::process::ExitCode;

fn run(args: &[String]) -> Result<(), String> {
    match args {
        [] => help(),
        [command] if command == "--help" => help(),
        [command, host, target] if command == "runtime-cell" => {
            gleam_mutants_release::runtime::cell(host, target)
        }
        [command] if command == "prove" => proofs::prove(),
        [command] if command == "audit-tools" => gleam_mutants_release::audit::audit(),
        [command] if command == "proposal-checks" => github::proposal_checks(),
        [command] if command == "controller-check" => {
            gleam_mutants_release::publication::controller_context()
        }
        [command] if command == "controller-outputs" => {
            gleam_mutants_release::publication::controller_outputs()
        }
        [command, directory] if command == "collect-inputs" => {
            github::collect(Path::new(directory))
        }
        [command, directory] if command == "gates-local" || command == "gates-hosted" => {
            runner::gates(Path::new(directory), command == "gates-hosted")
        }
        [command, directory] if command == "runtimes-local" || command == "runtimes-hosted" => {
            runner::runtimes(Path::new(directory), command == "runtimes-hosted")
        }
        [command, directory, version] if command == "check-dist" => {
            candidate::inspect(Path::new(directory), version)?;
            println!(
                "Distribution archives, checksums, product versions, and embedded dependency inventories match"
            );
            Ok(())
        }
        [command, directory] if command == "check-dist" => {
            let version = std::fs::read_to_string("VERSION").map_err(|e| e.to_string())?;
            candidate::inspect(Path::new(directory), version.trim())
        }
        [command, input, gates, runtimes, destination] if command == "stage-hosted" => {
            let candidate = runner::stage(
                Path::new(input),
                Path::new(gates),
                Path::new(runtimes),
                Path::new(destination),
            )?;
            runner::github_outputs(&candidate)
        }
        [command, directory, source, version, run, attempt]
            if command == "fetch"
                || command == "verify"
                || command == "attest-verify"
                || command == "plan" =>
        {
            let identity = github::expected(
                candidate::Revision::try_from(source.to_owned())?,
                candidate::Version::try_from(version.to_owned())?,
                run.parse()
                    .map_err(|_| "candidate run must be a positive integer")?,
                attempt
                    .parse()
                    .map_err(|_| "candidate attempt must be a positive integer")?,
            )?;
            let directory = Path::new(directory);
            if command == "fetch" {
                github::fetch(directory, &identity)?;
            } else {
                evidence::Candidate::load(directory)?.verify(directory, &identity)?;
                if command == "attest-verify" {
                    github::attestations(directory, &identity)?;
                }
                if command == "plan" {
                    gleam_mutants_release::publication::plan(directory, &identity)?;
                }
            }
            println!("Candidate source, build, artifacts, and verification inventory match");
            Ok(())
        }
        _ => Err("unknown or malformed preparation command; use --help".into()),
    }
}

fn help() -> Result<(), String> {
    println!(
        "gleam-mutants-release\n\ncheck-dist DIRECTORY VERSION\ngates-local OUTPUT_DIRECTORY\nruntimes-local OUTPUT_DIRECTORY\ngates-hosted OUTPUT_DIRECTORY\nruntimes-hosted OUTPUT_DIRECTORY\nstage-hosted BUILD_DIRECTORY GATE_DIRECTORY RUNTIME_DIRECTORY OUTPUT_DIRECTORY\nverify DIRECTORY SOURCE VERSION RUN ATTEMPT\nfetch DIRECTORY SOURCE VERSION RUN ATTEMPT\nprove\nproposal-checks\n\nPreparation has no tag, signing, release, or registry-publication operation."
    );
    Ok(())
}

fn main() -> ExitCode {
    match run(&std::env::args().skip(1).collect::<Vec<_>>()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("release preparation refused: {error}");
            ExitCode::FAILURE
        }
    }
}
