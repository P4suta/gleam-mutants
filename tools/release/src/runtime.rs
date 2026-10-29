// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::runner;
use serde_json::Value;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn natural(value: &Value, field: &str) -> Result<u64, String> {
    value[field]
        .as_u64()
        .ok_or_else(|| format!("runtime report has no natural count: {field}"))
}

pub fn conclusive(report: &Value, target: &str) -> Result<(), String> {
    let score = &report["score"];
    let results = report["mutants"]
        .as_array()
        .ok_or("runtime report has no mutant outcomes")?;
    let rejected = report["rejected"]
        .as_array()
        .ok_or("runtime report has no compiler outcomes")?;
    let total = natural(score, "total")?;
    let killed = natural(score, "killed")?;
    let survived = natural(score, "survived")?;
    let counts = gleam_mutants_release_core::RuntimeCounts {
        total,
        killed,
        survived,
        timed_out: natural(score, "timed_out")?,
        errors: natural(score, "errors")?,
        results: results.len() as u64,
        executed: natural(&report["selection"], "executed")?,
        compile_errors: natural(&report["selection"], "compile_errors")?,
        rejected: rejected.len() as u64,
    };
    if report["schema_version"] != 1
        || report["tool"] != "gleam-mutants"
        || !gleam_mutants_release_core::conclusive_counts(counts)
        || report["selection"]["skipped"] != false
    {
        return Err("runtime compatibility is empty, cached, skipped, or inconclusive".into());
    }
    for result in results {
        if !matches!(result["aggregate"].as_str(), Some("killed" | "survived")) {
            return Err("runtime aggregate is inconclusive".into());
        }
        let outcomes = result["outcomes"]
            .as_array()
            .ok_or("runtime outcomes are missing")?;
        let [outcome] = outcomes.as_slice() else {
            return Err("runtime cell has ambiguous target outcomes".into());
        };
        if outcome["runtime"] != target
            || outcome["cached"] != false
            || outcome["outcome"] != result["aggregate"]
        {
            return Err("runtime cell is cached or reports another target or outcome".into());
        }
    }
    Ok(())
}

fn copy(source: &Path, destination: &Path) -> Result<(), String> {
    fs::create_dir(destination).map_err(|e| e.to_string())?;
    for entry in fs::read_dir(source).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        if entry.file_name() == "build" {
            continue;
        }
        let target = destination.join(entry.file_name());
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_dir() {
            copy(&entry.path(), &target)?;
        } else if kind.is_file() {
            fs::copy(entry.path(), target).map_err(|e| e.to_string())?;
        } else {
            return Err("runtime fixture contains a link or special entry".into());
        }
    }
    Ok(())
}

pub fn cell(host: &str, target: &str) -> Result<(), String> {
    if !crate::evidence::RUNTIMES.contains(&host) || !crate::evidence::RUNTIMES.contains(&target) {
        return Err("unknown runtime cell".into());
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let temporary = std::env::temp_dir().join(format!(
        "gleam-mutants-runtime-{}-{nonce}",
        std::process::id()
    ));
    copy(Path::new("fixtures/basic_project"), &temporary)?;
    let result = execute(&temporary, host, target);
    let cleanup = fs::remove_dir_all(&temporary);
    match (result, cleanup) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) => Err(error),
        (Ok(()), Err(error)) => Err(format!("runtime fixture cleanup: {error}")),
        (Err(error), Err(cleanup)) => Err(format!("{error}; runtime fixture cleanup: {cleanup}")),
    }
}

fn execute(temporary: &Path, host: &str, target: &str) -> Result<(), String> {
    use std::io::Write;
    let target_name = if target == "erlang" {
        "erlang"
    } else {
        "javascript"
    };
    let config = format!(
        "\n[tools.gleam_mutants.test]\ntarget = \"{target_name}\"\nruntime = \"{target}\"\n\n[tools.gleam_mutants.policy]\nstrict = false\nminimum_score = 100\nrequire_mutants = true\n\n[tools.gleam_mutants.report]\ndirectory = \"reports/mutation\"\nformats = [\"json\"]\nhistory = false\n"
    );
    fs::OpenOptions::new()
        .append(true)
        .open(temporary.join("gleam.toml"))
        .map_err(|e| e.to_string())?
        .write_all(config.as_bytes())
        .map_err(|e| e.to_string())?;
    let root = temporary
        .to_str()
        .ok_or("runtime fixture path is not UTF-8")?;
    let args = [
        "--root",
        root,
        "run",
        "--json",
        "--no-strict",
        "--report",
        "none",
        "--jobs",
        "2",
    ];
    let output = if host == "deno" {
        runner::output(Command::new("gleam").args(["build", "--target", "javascript"]))?;
        runner::output(
            Command::new("deno")
                .args(["run", "--allow-all", "scripts/deno-host.mjs"])
                .args(args),
        )?
    } else {
        let mut command = Command::new("gleam");
        command.args([
            "run",
            "-m",
            "gleam_mutants",
            "--target",
            if host == "erlang" {
                "erlang"
            } else {
                "javascript"
            },
        ]);
        if host != "erlang" {
            command.args(["--runtime", host]);
        }
        runner::output(command.arg("--").args(args))?
    };
    let report: Value = serde_json::from_slice(&output.stdout)
        .map_err(|e| format!("native runtime report: {e}"))?;
    conclusive(&report, target)?;
    println!(
        "Runtime cell {host}/{target} has {} conclusive uncached outcomes",
        natural(&report["score"], "total")?
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::conclusive;

    fn report() -> serde_json::Value {
        serde_json::json!({"schema_version":1,"tool":"gleam-mutants","score":{"total":1,"killed":1,"survived":0,"timed_out":0,"errors":0},
            "selection":{"executed":1,"compile_errors":0,"skipped":false},"rejected":[],
            "mutants":[{"aggregate":"killed","outcomes":[{"runtime":"node","outcome":"killed","cached":false}]}]})
    }
    #[test]
    fn missing_cached_and_inconclusive_results_never_pass_a_runtime_cell() {
        let value = report();
        assert!(conclusive(&value, "node").is_ok());
        assert!(conclusive(&value, "bun").is_err());
        for field in ["errors", "timed_out", "total"] {
            let mut value = value.clone();
            value["score"][field] = serde_json::json!(0);
            if field != "total" {
                value["score"][field] = serde_json::json!(1);
            }
            assert!(conclusive(&value, "node").is_err());
        }
        let mut cached = value.clone();
        cached["mutants"][0]["outcomes"][0]["cached"] = serde_json::json!(true);
        assert!(conclusive(&cached, "node").is_err());
        let mut missing = value;
        missing["mutants"] = serde_json::json!([]);
        assert!(conclusive(&missing, "node").is_err());
    }
}
