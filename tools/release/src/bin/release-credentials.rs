// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use gleam_mutants_release::{credentials, registry::Registry};
use std::process::ExitCode;

fn run(args: &[String]) -> Result<(), String> {
    let [registry, username] = args else {
        return Err("usage: release-credentials hex|npm EXPECTED_USERNAME".into());
    };
    let registry = match registry.as_str() {
        "hex" => Registry::Hex,
        "npm" => Registry::Npm,
        _ => return Err("unknown credential registry".into()),
    };
    credentials::verify(registry, username)
}

fn main() -> ExitCode {
    match run(&std::env::args().skip(1).collect::<Vec<_>>()) {
        Ok(()) => {
            println!(
                "Registry authentication metadata matches; publication permission and trusted-publisher exchange were not tested"
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("credential verification refused: {error}");
            ExitCode::FAILURE
        }
    }
}
