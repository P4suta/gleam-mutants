// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::candidate::{self, Revision, Version};
use crate::evidence::{self, Candidate, Identity, Origin, Receipt, ResultRecord, Verdict};
use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output};

pub fn output(command: &mut Command) -> Result<Output, String> {
    let name = command.get_program().to_string_lossy().into_owned();
    let result = command.output().map_err(|e| format!("start {name}: {e}"))?;
    if !result.status.success() {
        return Err(format!(
            "{name} failed with {}: {}",
            result.status,
            String::from_utf8_lossy(&result.stderr)
        ));
    }
    Ok(result)
}

pub fn git(args: &[&str]) -> Result<String, String> {
    String::from_utf8(output(Command::new("git").args(args))?.stdout)
        .map(|v| v.trim().to_owned())
        .map_err(|e| e.to_string())
}

pub fn environment(name: &str) -> Result<String, String> {
    env::var(name).map_err(|_| format!("required environment input is missing: {name}"))
}

pub fn hosted_identity(source: Revision, version: Version) -> Result<Identity, String> {
    let expected_workflow = format!(
        "{}/{}@refs/heads/main",
        candidate::REPOSITORY,
        candidate::CANDIDATE_WORKFLOW
    );
    if environment("GITHUB_ACTIONS")? != "true"
        || environment("GITHUB_REF")? != "refs/heads/main"
        || environment("GITHUB_REF_PROTECTED")? != "true"
        || environment("GITHUB_WORKFLOW_REF")? != expected_workflow
        || environment("GITHUB_SHA")? != source.as_str()
        || environment("CANDIDATE_SOURCE")? != source.as_str()
    {
        return Err(
            "candidate execution requires the protected main workflow at its exact source commit"
                .into(),
        );
    }
    let identity = Identity {
        source,
        version,
        origin: Origin::GitHub {
            repository: environment("GITHUB_REPOSITORY")?,
            repository_id: environment("GITHUB_REPOSITORY_ID")?
                .parse()
                .map_err(|_| "invalid repository ID")?,
            owner_id: environment("GITHUB_REPOSITORY_OWNER_ID")?
                .parse()
                .map_err(|_| "invalid owner ID")?,
            workflow: candidate::CANDIDATE_WORKFLOW.into(),
            run: environment("GITHUB_RUN_ID")?
                .parse()
                .map_err(|_| "invalid run ID")?,
            attempt: environment("GITHUB_RUN_ATTEMPT")?
                .parse()
                .map_err(|_| "invalid run attempt")?,
        },
    };
    identity.hosted()?;
    Ok(identity)
}

pub fn current_identity(hosted: bool) -> Result<Identity, String> {
    let source = Revision::try_from(git(&["rev-parse", "HEAD"])?)?;
    let version = Version::try_from(
        fs::read_to_string("VERSION")
            .map_err(|e| e.to_string())?
            .trim()
            .to_owned(),
    )?;
    if !git(&["status", "--porcelain", "--untracked-files=normal"])?.is_empty() {
        return Err("candidate verification requires a clean tracked source tree".into());
    }
    if hosted {
        hosted_identity(source, version)
    } else {
        Ok(Identity {
            source,
            version,
            origin: Origin::Local,
        })
    }
}

fn prepare_directory(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    fs::create_dir(path).map_err(|e| format!("fresh evidence directory {}: {e}", path.display()))
}

fn run_check(
    command: &mut Command,
    name: &str,
    record: &mut Receipt,
    path: &Path,
) -> Result<(), String> {
    println!("{{\"phase\":\"{name}\",\"event\":\"started\"}}");
    let status = command
        .status()
        .map_err(|e| format!("start check {name}: {e}"))?;
    let verdict = if status.success() {
        Verdict::Passed
    } else {
        Verdict::Failed
    };
    record.results.push(ResultRecord {
        check: name.into(),
        verdict,
    });
    if !status.success() {
        evidence::write_new(path, record)?;
        return Err(format!("check {name} did not pass: {status}"));
    }
    println!("{{\"phase\":\"{name}\",\"event\":\"passed\"}}");
    Ok(())
}

pub fn gates(directory: &Path, hosted: bool) -> Result<(), String> {
    let identity = current_identity(hosted)?;
    prepare_directory(directory)?;
    let path = directory.join(evidence::GATE_RECEIPT);
    let mut record = Receipt {
        format: candidate::FORMAT,
        identity: identity.clone(),
        platform: env::consts::OS.into(),
        results: Vec::new(),
    };
    for gate in evidence::GATES {
        run_check(
            Command::new("mise").args(["run", gate]),
            gate,
            &mut record,
            &path,
        )?;
        if current_identity(hosted)? != identity {
            return Err("source changed during candidate checks".into());
        }
    }
    evidence::write_new(&path, &record)
}

pub fn runtimes(directory: &Path, hosted: bool) -> Result<(), String> {
    let identity = current_identity(hosted)?;
    prepare_directory(directory)?;
    let platform = env::consts::OS;
    if !evidence::PLATFORMS.contains(&platform) {
        return Err("unsupported candidate platform".into());
    }
    let path = directory.join(format!("runtime-{platform}.json"));
    let mut record = Receipt {
        format: candidate::FORMAT,
        identity: identity.clone(),
        platform: platform.into(),
        results: Vec::new(),
    };
    for check in ["test-integration", "test-matrix"] {
        run_check(
            Command::new("mise").args(["run", check]),
            check,
            &mut record,
            &path,
        )?;
    }
    for host in evidence::RUNTIMES {
        for target in evidence::RUNTIMES {
            crate::runtime::cell(host, target)?;
            record.results.push(ResultRecord {
                check: format!("{host}/{target}"),
                verdict: Verdict::Passed,
            });
        }
    }
    if current_identity(hosted)? != identity {
        return Err("source changed during runtime checks".into());
    }
    evidence::write_new(&path, &record)
}

pub fn stage(
    input: &Path,
    gates: &Path,
    runtimes: &Path,
    destination: &Path,
) -> Result<Candidate, String> {
    let identity = current_identity(true)?;
    let artifacts = candidate::distribution(input, &identity.version)?;
    let receipt = evidence::receipt(gates, evidence::GATE_RECEIPT)?;
    receipt.validate(&identity, "linux", &evidence::GATES.map(str::to_owned))?;
    let mut runtime_receipts = Vec::new();
    for platform in evidence::PLATFORMS {
        let name = format!("runtime-{platform}.json");
        let receipt = evidence::receipt(runtimes, &name)?;
        receipt.validate(&identity, platform, &evidence::runtime_checks())?;
        runtime_receipts.push((name, receipt));
    }
    prepare_directory(destination)?;
    let mut sums = String::new();
    for item in artifacts {
        let name = candidate::basename(&item.path)?;
        evidence::write_bytes_new(
            &destination.join(&name),
            &candidate::read(input, &item.path)?,
        )?;
        sums.push_str(&format!("{}  {name}\n", item.sha256));
    }
    evidence::write_bytes_new(&destination.join("SHA256SUMS"), sums.as_bytes())?;
    evidence::write_new(&destination.join(evidence::GATE_RECEIPT), &receipt)?;
    for (name, receipt) in runtime_receipts {
        evidence::write_new(&destination.join(name), &receipt)?;
    }
    Candidate::seal(destination, identity)
}

pub fn github_outputs(candidate: &Candidate) -> Result<(), String> {
    let path = environment("GITHUB_OUTPUT")?;
    let npm = candidate.npm()?;
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    let values = [
        ("artifact", candidate.identity.artifact_name()?),
        ("source", candidate.identity.source.as_str().into()),
        ("version", candidate.identity.version.as_str().into()),
        (
            "npm-subject",
            format!(
                "pkg:npm/gleam-mutants@{}",
                candidate.identity.version.as_str()
            ),
        ),
        ("npm-sha512", format!("sha512:{}", npm.sha512)),
    ];
    for (key, value) in values {
        if value.contains(['\r', '\n']) {
            return Err("workflow output contains a line break".into());
        }
        writeln!(file, "{key}={value}").map_err(|e| e.to_string())?;
    }
    Ok(())
}
