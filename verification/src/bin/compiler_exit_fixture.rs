// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::process::ExitCode;

const INTERRUPTED_EXIT_CODE: u8 = 130;
const TERMINATED_EXIT_CODE: u8 = 143;

fn main() -> ExitCode {
    match std::env::var("GLEAM_MUTANTS_INTERRUPT_CODE")
        .ok()
        .and_then(|value| value.parse::<u8>().ok())
    {
        Some(code @ (INTERRUPTED_EXIT_CODE | TERMINATED_EXIT_CODE)) => {
            eprintln!("compiler-interrupt-output");
            ExitCode::from(code)
        }
        _ => ExitCode::FAILURE,
    }
}
