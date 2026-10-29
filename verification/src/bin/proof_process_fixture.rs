// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::process::ExitCode;
use std::thread;

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("block") => loop {
            thread::park();
        },
        Some("success") => ExitCode::SUCCESS,
        Some("failure") | None => ExitCode::FAILURE,
        Some(_) => ExitCode::FAILURE,
    }
}
