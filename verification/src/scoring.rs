// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::fragment::{bind, boolean, choice};

pub fn derive_score(source: &str) -> Result<String, String> {
    let values = bind(source, include_str!("../fragments/score.gleam.in"))?;
    let constructor = |name| match choice(&values, name, &["Killed", "TimedOut", "Survived"])? {
        "Killed" => Ok::<_, String>("Outcome.killed"),
        "TimedOut" => Ok("Outcome.timedOut"),
        "Survived" => Ok("Outcome.survived"),
        _ => unreachable!("choice checks the constructor domain"),
    };
    let operation = |name| choice(&values, name, &["+", "-"]);
    let zero = choice(&values, "__zero_case", &["0", "1"])?;
    Ok(format!(
        "namespace ScoreDerived\nopen OutcomeDerived\ninductive PercentTerm where\n  | zero\n  | divideMultiply (numerator denominator scale : Int)\n  deriving DecidableEq\nstructure Score where\n  total : Int\n  killed : Int\n  timed_out : Int\n  survived : Int\n  errors : Int\n  percent : PercentTerm\n  deriving DecidableEq\ndef count (values : List Outcome) (predicate : Outcome → Bool) : Int := Int.ofNat (values.filter predicate).length\ndef calculate (values : List Outcome) : Score :=\n  let killed := count values (fun value => decide (value = {}))\n  let timed_out := count values (fun value => decide (value = {}))\n  let survived := count values (fun value => decide (value = {}))\n  let total := killed {} timed_out {} survived\n  let errors := Int.ofNat values.length {} total\n  let percent := if total = {zero} then PercentTerm.zero else PercentTerm.divideMultiply (killed {} timed_out) total 100\n  ⟨total, killed, timed_out, survived, errors, percent⟩\nend ScoreDerived\n",
        constructor("__killed")?,
        constructor("__timed_out")?,
        constructor("__survived")?,
        operation("__first_sum")?,
        operation("__second_sum")?,
        operation("__error_operation")?,
        operation("__numerator_operation")?
    ))
}

pub fn derive_policy(source: &str) -> Result<String, String> {
    let values = bind(source, include_str!("../fragments/exit_policy.gleam.in"))?;
    Ok(format!(
        "namespace PolicyDerived\ndef strict (override : Option Bool) : Bool := match override with\n  | some value => value\n  | none => {}\ndef code (errors : Int) (override : Option Bool) (belowThreshold : Bool) : Int :=\n  match (decide (errors {} 0), strict override {} belowThreshold) with\n  | (true, _) => {}\n  | (false, true) => {}\n  | (false, false) => {}\nend PolicyDerived\n",
        boolean(&values, "__default")?,
        choice(
            &values,
            "__error_comparison",
            &[">", ">=", "<", "<=", "==", "!="]
        )
        .map(|operator| match operator {
            "==" => "=",
            "!=" => "≠",
            other => other,
        })?,
        choice(&values, "__connective", &["&&", "||"])?,
        choice(&values, "__error_code", &["0", "1", "2"])?,
        choice(&values, "__threshold_code", &["0", "1", "2"])?,
        choice(&values, "__success_code", &["0", "1", "2"])?
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    const SCORE: &str = include_str!("../../src/gleam_mutants/core/score.gleam");
    const POLICY: &str = include_str!("../../src/gleam_mutants/core/exit_policy.gleam");

    #[test]
    fn derives_actual_count_arithmetic_and_retains_the_float_boundary() {
        let original = derive_score(SCORE).unwrap();
        assert!(original.contains("PercentTerm"));
        assert_ne!(
            derive_score(&SCORE.replace(
                "killed + timed_out + survived",
                "killed + timed_out - survived"
            ))
            .unwrap(),
            original
        );
        assert_ne!(
            derive_score(&SCORE.replace(
                "list.length(outcomes) - total",
                "list.length(outcomes) + total"
            ))
            .unwrap(),
            original
        );
        assert!(derive_score(&SCORE.replace("list.filter", "list.map")).is_err());
        assert_eq!(
            derive_score(SCORE),
            derive_score(&crate::fragment::tokens(SCORE).unwrap().join(" "))
        );
    }

    #[test]
    fn derives_explicit_policy_override_and_all_exit_branches() {
        let original = derive_policy(POLICY).unwrap();
        assert_ne!(
            derive_policy(&POLICY.replace("None -> False", "None -> True")).unwrap(),
            original
        );
        assert_ne!(
            derive_policy(&POLICY.replace("True, _ -> 2", "True, _ -> 0")).unwrap(),
            original
        );
        assert!(derive_policy(&POLICY.replace("strict(context)", "context.ci")).is_err());
        assert_eq!(
            derive_policy(POLICY),
            derive_policy(&crate::fragment::tokens(POLICY).unwrap().join(" "))
        );
    }
}
