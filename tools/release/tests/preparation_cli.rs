// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::process::Command;

#[test]
fn preparation_has_no_tag_sign_or_publish_command() {
    for operation in ["publish", "tag", "sign", "release", "finalize"] {
        let output = Command::new(env!("CARGO_BIN_EXE_gleam-mutants-release"))
            .arg(operation)
            .output()
            .unwrap();
        assert!(!output.status.success(), "{operation}");
    }
}

#[test]
fn publication_has_no_local_authority() {
    for phase in ["draft", "hex", "npm", "finalize"] {
        let output = Command::new(env!("CARGO_BIN_EXE_release-publish"))
            .args([
                "execute",
                phase,
                "absent-candidate",
                &"a".repeat(40),
                "0.1.0",
                "1",
                "1",
            ])
            .env_remove("GITHUB_ACTIONS")
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("GITHUB_ACTIONS"));
    }
}
