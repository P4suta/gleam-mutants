// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::{candidate, constants, runner};
use std::fs;
use std::path::PathBuf;
use std::process::Command;

pub fn audit() -> Result<(), String> {
    let revision =
        candidate::Revision::try_from(include_str!("../rustsec.commit").trim().to_owned())?;
    let directory = PathBuf::from(format!("build/rustsec/{}", revision.as_str()));
    if !directory.exists() {
        if let Some(parent) = directory.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        runner::output(Command::new("git").arg("init").arg(&directory))?;
        runner::output(Command::new("git").arg("-C").arg(&directory).args([
            "remote",
            "add",
            "origin",
            constants::RUSTSEC_REPOSITORY,
        ]))?;
        runner::output(Command::new("git").arg("-C").arg(&directory).args([
            "fetch",
            "--depth=1",
            "origin",
            revision.as_str(),
        ]))?;
        runner::output(Command::new("git").arg("-C").arg(&directory).args([
            "checkout",
            "--detach",
            "FETCH_HEAD",
        ]))?;
    }
    let observed = runner::output(
        Command::new("git")
            .arg("-C")
            .arg(&directory)
            .args(["rev-parse", "HEAD"]),
    )?;
    if String::from_utf8_lossy(&observed.stdout).trim() != revision.as_str() {
        return Err("RustSec cache revision differs from the pinned input".into());
    }
    let clean = runner::output(Command::new("git").arg("-C").arg(&directory).args([
        "status",
        "--porcelain",
        "--untracked-files=normal",
    ]))?;
    if !clean.stdout.is_empty() {
        return Err("RustSec cache contains modified or untracked inputs".into());
    }
    let report = runner::output(
        Command::new("cargo")
            .args([
                "audit",
                "--file",
                "tools/Cargo.lock",
                "--no-fetch",
                "--json",
                "--db",
            ])
            .arg(&directory),
    )?;
    let report: serde_json::Value =
        serde_json::from_slice(&report.stdout).map_err(|e| e.to_string())?;
    if report["vulnerabilities"]["found"] != false || report["vulnerabilities"]["count"] != 0 {
        return Err("locked release dependencies have known vulnerabilities".into());
    }
    println!(
        "Locked release dependencies passed RustSec revision {}",
        revision.as_str()
    );
    Ok(())
}
