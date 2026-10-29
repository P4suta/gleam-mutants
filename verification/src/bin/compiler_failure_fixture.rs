// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::fs;
use std::io::ErrorKind;
use std::process::{Command, ExitCode};

const FIRST_BUILD: usize = 0;

fn run() -> Result<ExitCode, String> {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    if arguments
        .first()
        .is_some_and(|argument| argument == "build")
    {
        let counter =
            std::env::var_os("GLEAM_MUTANTS_COMPILER_COUNTER").ok_or("missing fixture counter")?;
        let count = match fs::read_to_string(&counter) {
            Ok(value) => value.parse::<usize>().map_err(|e| e.to_string())?,
            Err(error) if error.kind() == ErrorKind::NotFound => FIRST_BUILD,
            Err(error) => return Err(format!("read fixture counter: {error}")),
        };
        fs::write(counter, (count + 1).to_string())
            .map_err(|e| format!("write fixture counter: {e}"))?;
        if count != FIRST_BUILD {
            let code = std::env::var("GLEAM_MUTANTS_COMPILER_FAILURE_CODE")
                .map_err(|e| e.to_string())?
                .parse::<u8>()
                .map_err(|e| e.to_string())?;
            eprintln!("compiler-fixture-failure");
            return Ok(ExitCode::from(code));
        }
    }
    let compiler =
        std::env::var_os("GLEAM_MUTANTS_REAL_COMPILER").ok_or("missing real fixture compiler")?;
    let status = Command::new(compiler)
        .args(arguments)
        .status()
        .map_err(|e| format!("run real fixture compiler: {e}"))?;
    let code = status
        .code()
        .ok_or("real fixture compiler ended by signal")?;
    Ok(ExitCode::from(
        u8::try_from(code).map_err(|e| e.to_string())?,
    ))
}

fn main() -> ExitCode {
    match run() {
        Ok(status) => status,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
