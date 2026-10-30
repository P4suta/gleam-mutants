// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::fragment::{bind, boolean, choice, scalar_literal};

const TEMPLATE: &str = include_str!("../fragments/outcome.gleam.in");

pub fn derive(source: &str) -> Result<String, String> {
    let values = bind(source, TEMPLATE)?;
    let mut model = "namespace OutcomeDerived\ninductive Runtime where\n  | erlang | node | deno | bun\n  deriving DecidableEq\ninductive Outcome where\n  | killed | survived | timedOut\n  | testError (message : List Nat)\n  deriving DecidableEq\n".to_owned();
    model.push_str("def runtime_name (runtime : Runtime) : List Nat := match runtime with\n");
    for runtime in ["erlang", "node", "deno", "bun"] {
        model.push_str(&format!(
            "  | .{runtime} => {}\n",
            scalar_literal(&values, &format!("__{runtime}"))?
        ));
    }
    model.push_str(&format!("def detected (value : Outcome) : Bool := match value with\n  | .killed | .timedOut => {}\n  | .survived | .testError _ => {}\n", boolean(&values, "__detected")?, boolean(&values, "__undetected")?));
    model.push_str(&format!("def isError (value : Outcome) : Bool := match value with\n  | .testError _ => {}\n  | _ => {}\n", boolean(&values, "__error")?, boolean(&values, "__nonerror")?));
    let outcome = |name| match choice(&values, name, &["Killed", "Survived", "TimedOut"])? {
        "Killed" => Ok::<_, String>("Outcome.killed"),
        "Survived" => Ok("Outcome.survived"),
        "TimedOut" => Ok("Outcome.timedOut"),
        _ => unreachable!("choice checks the constructor domain"),
    };
    model.push_str(&format!(
        "def aggregate_nonempty (values : List Outcome) : Outcome :=\n  match values.find? isError with\n  | some item => item\n  | none => if values.any (fun item => decide (item = {})) then {}\n    else if values.any (fun item => decide (item = {})) then {} else {}\n",
        outcome("__first_search")?, outcome("__first_result")?, outcome("__second_search")?, outcome("__second_result")?, outcome("__fallback")?
    ));
    model.push_str(&format!("def aggregate (values : List Outcome) : Outcome := match values with\n  | [] => .testError {}\n  | _ => aggregate_nonempty values\n", scalar_literal(&values, "__empty")?));
    model.push_str(&format!("def is_detected (value : Outcome) : Bool :=\n  decide (value = {}) {} decide (value = {})\nend OutcomeDerived\n", outcome("__left")?, choice(&values, "__connective", &["||", "&&"] )?, outcome("__right")?));
    Ok(model)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = include_str!("../../src/gleam_mutants/core/outcome.gleam");

    #[test]
    fn derives_error_payloads_and_priority_from_the_complete_module() {
        let model = derive(SOURCE).expect("supported production outcome module");
        assert!(model.contains("def aggregate"));
        assert!(model.contains("List Nat"));
        for broken in [
            SOURCE.replacen("Killed | TimedOut -> True", "Killed | TimedOut -> False", 1),
            SOURCE.replacen("True -> Survived", "True -> TimedOut", 1),
            SOURCE.replacen("TestError(_) -> True", "TestError(_) -> False", 1),
        ] {
            assert_ne!(derive(&broken).unwrap(), model);
        }
    }

    #[test]
    fn rejects_unmodeled_calls_and_preserves_token_round_trips() {
        assert_eq!(
            derive(SOURCE),
            derive(&crate::fragment::tokens(SOURCE).unwrap().join(" "))
        );
        assert!(derive(&SOURCE.replace("list.find", "list.last")).is_err());
        assert!(derive(&format!("{SOURCE}\npub fn hidden() {{ True }}")).is_err());
    }
}
