// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::candidate::{self, Revision};
use crate::{github, runner};
use serde_json::{Value, json};
use std::io::Write;
use std::process::{Command, Output, Stdio};

fn input(command: &mut Command, bytes: &[u8]) -> Result<Output, String> {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("start proposal preparation: {e}"))?;
    let written = match child.stdin.take() {
        Some(mut stdin) => stdin.write_all(bytes),
        None => Err(std::io::Error::other("missing proposal input")),
    };
    if let Err(error) = written {
        let killed = child.kill();
        let reaped = child.wait();
        return Err(format!(
            "proposal input failed: {error}; cleanup kill={killed:?}, wait={reaped:?}"
        ));
    }
    let output = child
        .wait_with_output()
        .map_err(|e| format!("proposal preparation completion is uncertain: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "proposal preparation failed: {}; inspect remote state before retry: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(output)
}

fn format_changelog(source: &str) -> Result<String, String> {
    if source.trim().is_empty() {
        return Err("proposal changelog is empty".into());
    }
    let output = input(
        Command::new("rumdl").args([
            "fmt",
            "--enable",
            "MD004,MD012",
            "--stdin-filename",
            "CHANGELOG.md",
            "--silent",
            "-",
        ]),
        source.as_bytes(),
    )?;
    let formatted = String::from_utf8(output.stdout).map_err(|e| e.to_string())?;
    if formatted.trim().is_empty() {
        return Err("proposal formatter returned an empty changelog".into());
    }
    input(
        Command::new("rumdl").args(["check", "--stdin-filename", "CHANGELOG.md", "--silent", "-"]),
        formatted.as_bytes(),
    )?;
    Ok(formatted)
}

fn write(method: &str, endpoint: &str, body: &Value) -> Result<Value, String> {
    let bytes = serde_json::to_vec(body).map_err(|e| e.to_string())?;
    let output = input(
        Command::new("gh").args(["api", "--method", method, "--input", "-", endpoint]),
        &bytes,
    )?;
    serde_json::from_slice(&output.stdout).map_err(|e| format!("proposal response: {e}"))
}

fn revision(value: &Value) -> Result<Revision, String> {
    Revision::try_from(
        value
            .as_str()
            .ok_or("proposal revision is missing")?
            .to_owned(),
    )
}

pub(crate) fn format(number: u64, source: &Revision) -> Result<Revision, String> {
    let endpoint = format!(
        "repos/{}/contents/CHANGELOG.md?ref={}",
        candidate::REPOSITORY,
        source.as_str()
    );
    let original = runner::output(Command::new("gh").args([
        "api",
        "--header",
        "Accept: application/vnd.github.raw+json",
        &endpoint,
    ]))?;
    let original = String::from_utf8(original.stdout).map_err(|e| e.to_string())?;
    let formatted = format_changelog(&original)?;
    if formatted == original {
        return Ok(source.clone());
    }
    for (name, expected) in [
        ("GITHUB_ACTIONS", "true"),
        ("GITHUB_EVENT_NAME", "push"),
        ("GITHUB_REF", "refs/heads/main"),
        ("GITHUB_REF_PROTECTED", "true"),
        (
            "GITHUB_WORKFLOW_REF",
            "P4suta/gleam-mutants/.github/workflows/release-please.yml@refs/heads/main",
        ),
    ] {
        if runner::environment(name)? != expected {
            return Err("proposal formatting requires the protected preparation workflow".into());
        }
    }
    let current = github::required(&format!("repos/{}/pulls/{number}", candidate::REPOSITORY))?;
    github::validate_proposal(&current)?;
    if current["head"]["sha"] != source.as_str() {
        return Err("proposal head changed before formatting".into());
    }
    let prefix = format!("repos/{}/git", candidate::REPOSITORY);
    let commit = github::required(&format!("{prefix}/commits/{}", source.as_str()))?;
    let base_tree = revision(&commit["tree"]["sha"])?;
    let blob = write(
        "POST",
        &format!("{prefix}/blobs"),
        &json!({"encoding":"utf-8","content":formatted}),
    )?;
    let blob = revision(&blob["sha"])?;
    let tree = write(
        "POST",
        &format!("{prefix}/trees"),
        &json!({"base_tree":base_tree.as_str(),"tree":[{"path":"CHANGELOG.md","mode":"100644","type":"blob","sha":blob.as_str()}]}),
    )?;
    let tree = revision(&tree["sha"])?;
    let commit = write(
        "POST",
        &format!("{prefix}/commits"),
        &json!({"message":"chore(release): format generated changelog","tree":tree.as_str(),"parents":[source.as_str()]}),
    )?;
    let head = revision(&commit["sha"])?;
    write(
        "PATCH",
        &format!("{prefix}/refs/heads/{}", github::PROPOSAL_BRANCH),
        &json!({"sha":head.as_str(),"force":false}),
    )?;
    Ok(head)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_notes_pass_markdown_without_losing_entries() {
        let generated = "# Changelog\n\n\n## 0.1.0\n\n\n* Added [discovery](https://example.com/discovery).\n- Fixed cleanup.\n";
        let formatted = format_changelog(generated).unwrap();
        assert_eq!(
            formatted,
            "# Changelog\n\n## 0.1.0\n\n- Added [discovery](https://example.com/discovery).\n- Fixed cleanup.\n"
        );
        assert_eq!(format_changelog(&formatted).unwrap(), formatted);
        assert!(format_changelog("\n\n").is_err());
        assert!(format_changelog("# Changelog\n\n### Skipped level\n").is_err());
    }
}
