// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

const EXPECTED_CONSTRUCTORS: usize = 64;
const EXPECTED_SPAN_PAIRS: usize = 784;
const EXPECTED_OUTCOME_LISTS: usize = 781;
const EXPECTED_POLICY_STATES: usize = 18;
const EXPECTED_OPERATORS: usize = 15;
const EXPECTED_RUNTIMES: usize = 4;
const EXPECTED_DETECTION_CASES: usize = 5;
const EXPECTED_PATH_CASES: usize = 30;
const EXPECTED_GLOB_CASES: usize = 5467;
const EXPECTED_PLAN_CASES: usize = 14;

const INVENTORY: &[(&str, usize)] = &[
    ("bridge:constructor:", EXPECTED_CONSTRUCTORS),
    ("bridge:span:", EXPECTED_SPAN_PAIRS),
    ("bridge:outcome:", EXPECTED_OUTCOME_LISTS),
    ("bridge:policy:", EXPECTED_POLICY_STATES),
    ("bridge:operator:", EXPECTED_OPERATORS),
    ("bridge:runtime:", EXPECTED_RUNTIMES),
    ("bridge:detection:", EXPECTED_DETECTION_CASES),
    ("bridge:path:", EXPECTED_PATH_CASES),
    ("bridge:glob:", EXPECTED_GLOB_CASES),
    ("bridge:plan:", EXPECTED_PLAN_CASES),
];

pub fn records(output: &str) -> Result<Vec<&str>, String> {
    let lines: Vec<_> = output
        .lines()
        .filter(|line| line.starts_with("bridge:"))
        .collect();
    for &(prefix, expected) in INVENTORY {
        let actual = lines.iter().filter(|line| line.starts_with(prefix)).count();
        if actual != expected {
            return Err(format!(
                "{prefix} inventory is {actual}, expected {expected}"
            ));
        }
    }
    if lines.len() != INVENTORY.iter().map(|(_, count)| count).sum::<usize>() {
        return Err("unexpected native model-link records".into());
    }
    if lines
        .iter()
        .collect::<std::collections::BTreeSet<_>>()
        .len()
        != lines.len()
    {
        return Err("duplicated native model-link records".into());
    }
    Ok(lines)
}

pub fn compare(model: &str, implementation: &str) -> Result<(), String> {
    let expected = records(model)?;
    let actual = records(implementation)?;
    if let Some((index, (expected, actual))) = expected
        .iter()
        .zip(&actual)
        .enumerate()
        .find(|(_, (expected, actual))| expected != actual)
    {
        return Err(format!(
            "model-link mismatch at record {index}: expected {expected:?}, got {actual:?}"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn incomplete_or_empty_comparisons_never_pass() {
        assert!(compare("", "").is_err());
        assert!(records("bridge:outcome:only-one").is_err());
    }

    #[test]
    fn rejects_changed_reordered_or_duplicated_evidence() {
        let rows: Vec<_> = INVENTORY
            .iter()
            .flat_map(|(prefix, count)| (0..*count).map(move |index| format!("{prefix}{index}")))
            .collect();
        let original = rows.join("\n");
        compare(&original, &original).unwrap();
        let mut changed = rows.clone();
        changed[0].push_str(":wrong");
        assert!(compare(&original, &changed.join("\n")).is_err());
        changed = rows.clone();
        changed.swap(0, 1);
        assert!(compare(&original, &changed.join("\n")).is_err());
        changed[0] = changed[1].clone();
        assert!(records(&changed.join("\n")).is_err());
    }
}
