// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::{fs, path::Path};

const INPUTS: &[(&str, &str)] = &[
    ("verification/src/main.rs", include_str!("main.rs")),
    (
        "verification/Contracts.lean",
        include_str!("../Contracts.lean"),
    ),
    (
        "verification/SpanContracts.lean",
        include_str!("../SpanContracts.lean"),
    ),
    (
        "verification/OutcomeContracts.lean",
        include_str!("../OutcomeContracts.lean"),
    ),
    (
        "verification/ScoringContracts.lean",
        include_str!("../ScoringContracts.lean"),
    ),
    (
        "verification/SelectionContracts.lean",
        include_str!("../SelectionContracts.lean"),
    ),
    (
        "verification/PathContracts.lean",
        include_str!("../PathContracts.lean"),
    ),
    (
        "verification/GlobContracts.lean",
        include_str!("../GlobContracts.lean"),
    ),
    (
        "verification/ParentContracts.lean",
        include_str!("../ParentContracts.lean"),
    ),
    (
        "verification/src/configuration.rs",
        include_str!("configuration.rs"),
    ),
    (
        "verification/src/contracts.rs",
        include_str!("contracts.rs"),
    ),
    ("verification/src/lib.rs", include_str!("lib.rs")),
    (
        "verification/src/supervisor.rs",
        include_str!("supervisor.rs"),
    ),
    ("verification/src/limits.rs", include_str!("limits.rs")),
    (
        "verification/src/filesystem_entry.rs",
        include_str!("filesystem_entry.rs"),
    ),
    ("verification/src/span.rs", include_str!("span.rs")),
    ("verification/src/fragment.rs", include_str!("fragment.rs")),
    ("verification/src/outcome.rs", include_str!("outcome.rs")),
    ("verification/src/scoring.rs", include_str!("scoring.rs")),
    (
        "verification/src/selection.rs",
        include_str!("selection.rs"),
    ),
    ("verification/src/paths.rs", include_str!("paths.rs")),
    ("verification/src/bridge.rs", include_str!("bridge.rs")),
    (
        "verification/fragments/outcome.gleam.in",
        include_str!("../fragments/outcome.gleam.in"),
    ),
    (
        "verification/fragments/score.gleam.in",
        include_str!("../fragments/score.gleam.in"),
    ),
    (
        "verification/fragments/exit_policy.gleam.in",
        include_str!("../fragments/exit_policy.gleam.in"),
    ),
    (
        "verification/fragments/operator.gleam.in",
        include_str!("../fragments/operator.gleam.in"),
    ),
    (
        "verification/fragments/plan.gleam.in",
        include_str!("../fragments/plan.gleam.in"),
    ),
    (
        "verification/fragments/path.gleam.in",
        include_str!("../fragments/path.gleam.in"),
    ),
    (
        "verification/fragments/glob.gleam.in",
        include_str!("../fragments/glob.gleam.in"),
    ),
    ("verification/Cargo.toml", include_str!("../Cargo.toml")),
    ("verification/Dockerfile", include_str!("../Dockerfile")),
    ("verification/Bridge.lean", include_str!("../Bridge.lean")),
    (
        "test/proof_model_smoke.gleam",
        include_str!("../../test/proof_model_smoke.gleam"),
    ),
    ("gleam.toml", include_str!("../../gleam.toml")),
    ("manifest.toml", include_str!("../../manifest.toml")),
    ("mise.toml", include_str!("../../mise.toml")),
];

pub fn check() -> Result<(), String> {
    for &(path, compiled) in INPUTS {
        let current = fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
        if current != compiled {
            return Err(format!(
                "verifier configuration differs from compiled source: {path}"
            ));
        }
    }
    Ok(())
}

pub fn copy(directory: &Path) -> Result<(), String> {
    for &(path, compiled) in INPUTS {
        let target = directory.join("verifier").join(path);
        fs::create_dir_all(target.parent().ok_or("compiled input has no parent")?)
            .map_err(|error| error.to_string())?;
        fs::write(&target, compiled).map_err(|error| format!("{}: {error}", target.display()))?;
    }
    Ok(())
}
