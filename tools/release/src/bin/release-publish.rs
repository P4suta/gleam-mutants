// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use gleam_mutants_release::{candidate, github, publication};
use std::path::Path;
use std::process::ExitCode;

fn run(args: &[String]) -> Result<(), String> {
    match args {
        [command, phase, directory, source, version, run, attempt] if command == "execute" => {
            let phase = publication::Phase::parse(phase)?;
            let identity = github::expected(candidate::Revision::try_from(source.to_owned())?, candidate::Version::try_from(version.to_owned())?,
                run.parse().map_err(|_| "candidate run must be a positive integer")?, attempt.parse().map_err(|_| "candidate attempt must be a positive integer")?)?;
            publication::execute(phase, Path::new(directory), &identity)
        }
        _ => Err("usage: release-publish execute PHASE DIRECTORY SOURCE VERSION RUN ATTEMPT; execution requires the approved hosted phase".into()),
    }
}

fn main() -> ExitCode {
    match run(&std::env::args().skip(1).collect::<Vec<_>>()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("release publication refused: {error}");
            ExitCode::FAILURE
        }
    }
}
