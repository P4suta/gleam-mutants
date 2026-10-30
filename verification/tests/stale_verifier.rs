// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::{
    fs,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

#[test]
fn stale_compiled_configuration_cannot_derive_or_certify_current_sources()
-> Result<(), Box<dyn std::error::Error>> {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let root = std::env::temp_dir().join(format!(
        "gleam-mutants-stale-verifier-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir_all(root.join("verification/src"))?;
    fs::write(
        root.join("verification/src/main.rs"),
        "// changed after compilation\n",
    )?;
    let result = Command::new(env!("CARGO_BIN_EXE_gleam-mutants-verification"))
        .args(["derive", "output"])
        .current_dir(&root)
        .output();
    let cleanup = fs::remove_dir_all(&root);
    let output = match (result, cleanup) {
        (Ok(output), Ok(())) => output,
        (Err(primary), Ok(())) => return Err(primary.into()),
        (Ok(_), Err(cleanup)) => return Err(cleanup.into()),
        (Err(primary), Err(cleanup)) => {
            return Err(format!("{primary}; cleanup also failed: {cleanup}").into());
        }
    };
    assert!(!output.status.success());
    let error = String::from_utf8(output.stderr)?;
    assert!(
        error.contains(
            "verifier configuration differs from compiled source: verification/src/main.rs"
        ),
        "{error}"
    );
    Ok(())
}
