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

#[test]
fn credential_transport_has_no_local_or_publication_command() {
    for registry in ["hex", "npm", "publish", "sign", "tag"] {
        let output = Command::new(env!("CARGO_BIN_EXE_release-credentials"))
            .args([registry, "expected-user"])
            .env_remove("GITHUB_ACTIONS")
            .output()
            .unwrap();
        assert!(!output.status.success());
    }
}

#[test]
fn credential_verification_uses_only_identity_gets_and_stdin_authentication() {
    use gleam_mutants_release::candidate;
    let root =
        std::env::temp_dir().join(format!("gleam-release-credentials-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let executable = if cfg!(windows) { "curl.exe" } else { "curl" };
    std::fs::copy(
        env!("CARGO_BIN_EXE_registry-fixture"),
        root.join(executable),
    )
    .unwrap();
    let original_path = std::env::var_os("PATH").unwrap();
    let path = std::env::join_paths(
        std::iter::once(root.clone()).chain(std::env::split_paths(&original_path)),
    )
    .unwrap();
    for (registry, environment, key) in [
        ("hex", "release-hex", "HEXPM_API_KEY"),
        ("npm", "release-npm", "NPM_BOOTSTRAP_TOKEN"),
    ] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_release-credentials"));
        command
            .args([registry, "release-fixture"])
            .env("PATH", &path)
            .env("GITHUB_ACTIONS", "true")
            .env("GITHUB_REPOSITORY", candidate::REPOSITORY)
            .env("GITHUB_REPOSITORY_ID", candidate::REPOSITORY_ID.to_string())
            .env(
                "GITHUB_REPOSITORY_OWNER_ID",
                candidate::OWNER_ID.to_string(),
            )
            .env("GITHUB_EVENT_NAME", "workflow_dispatch")
            .env("GITHUB_REF", "refs/heads/main")
            .env("GITHUB_REF_PROTECTED", "true")
            .env(
                "GITHUB_WORKFLOW_REF",
                format!(
                    "{}/.github/workflows/release-credentials.yml@refs/heads/main",
                    candidate::REPOSITORY
                ),
            )
            .env("GITHUB_JOB", registry)
            .env("RELEASE_ENVIRONMENT", environment)
            .env(key, "fixture-key");
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        command.env(
            "GITHUB_WORKFLOW_REF",
            format!(
                "{}/.github/workflows/release-publish.yml@refs/heads/main",
                candidate::REPOSITORY
            ),
        );
        assert!(!command.output().unwrap().status.success());
    }
    std::fs::remove_dir_all(root).unwrap();
}
