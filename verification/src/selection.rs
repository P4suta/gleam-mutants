// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::fragment::{bind, choice, natural, scalar_literal};

const OPERATORS: &[&str] = &[
    "BooleanLiteral",
    "BooleanNegation",
    "BooleanConnective",
    "Equality",
    "ComparisonBoundary",
    "IntegerArithmetic",
    "FloatArithmetic",
    "IntegerNeutral",
    "FloatNeutral",
    "StringNeutral",
    "ListNeutral",
    "OptionNeutral",
    "PipelineStageDeletion",
    "ConcatenationOperand",
    "IntegerNegation",
];

pub fn derive_operator(source: &str) -> Result<String, String> {
    let values = bind(source, include_str!("../fragments/operator.gleam.in"))?;
    let mut model = "namespace OperatorDerived\ninductive Operator where\n".to_owned();
    for operator in OPERATORS {
        model.push_str(&format!("  | {operator}\n"));
    }
    model.push_str("  deriving DecidableEq\ndef all : List Operator := [");
    let all: Vec<_> = OPERATORS
        .iter()
        .map(|operator| {
            choice(&values, &format!("__all_{operator}"), OPERATORS)
                .map(|value| format!(".{value}"))
        })
        .collect::<Result<_, _>>()?;
    model.push_str(&all.join(", "));
    model.push_str("]\ndef name (operator : Operator) : List Nat := match operator with\n");
    for operator in OPERATORS {
        model.push_str(&format!(
            "  | .{operator} => {}\n",
            scalar_literal(&values, &format!("__name_{operator}"))?
        ));
    }
    model.push_str(&format!("def version (_ : Operator) : Int := {}\ndef from_name (value : List Nat) : Option Operator := all.find? (fun operator => decide (name operator = value))\nend OperatorDerived\n", natural(&values, "__version")?));
    Ok(model)
}

pub fn derive_plan(source: &str) -> Result<String, String> {
    let values = bind(source, include_str!("../fragments/plan.gleam.in"))?;
    Ok(format!(
        "namespace PlanDerived\nstructure Mutant where\n  id : List Nat\n  display_id : List Nat\n  deriving DecidableEq\ninductive Selection where\n  | all | changed\n  | single (needle : List Nat)\n  deriving DecidableEq\nstructure Plan where\n  selection : Selection\n  mutants : List Mutant\n  deriving DecidableEq\ninductive PlanError where\n  | noMatch (needle : List Nat)\n  | ambiguous (needle : List Nat)\n  deriving DecidableEq\ndef accepts (needle : List Nat) (mutant : Mutant) : Bool := needle.isPrefixOf mutant.id {} needle.isPrefixOf mutant.display_id\ndef build (values : List Mutant) (changed : Bool) (needle : Option (List Nat)) : Except PlanError Plan :=\n  match needle with\n  | none => .ok ⟨if changed then .{} else .{}, values⟩\n  | some needle => match values.filter (accepts needle) with\n    | [] => .error (.noMatch needle)\n    | [mutant] => .ok ⟨.single needle, [mutant]⟩\n    | _ => .error (.ambiguous needle)\ndef mutants (plan : Plan) : List Mutant := plan.mutants\ndef mode (plan : Plan) : List Nat := match plan.selection with\n  | .all => {}\n  | .changed => {}\n  | .single _ => {}\nend PlanDerived\n",
        choice(&values, "__connective", &["||", "&&"])?,
        choice(&values, "__changed", &["Changed", "All"]).map(|value| value.to_lowercase())?,
        choice(&values, "__all", &["Changed", "All"]).map(|value| value.to_lowercase())?,
        scalar_literal(&values, "__mode_all")?,
        scalar_literal(&values, "__mode_changed")?,
        scalar_literal(&values, "__mode_single")?
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    const OPERATOR: &str = include_str!("../../src/gleam_mutants/core/operator.gleam");
    const PLAN: &str = include_str!("../../src/gleam_mutants/core/plan.gleam");

    #[test]
    fn derives_operator_inventory_names_and_versions() {
        let original = derive_operator(OPERATOR).unwrap();
        for source in [
            OPERATOR.replace("\"equality\"", "\"integer-neutral\""),
            OPERATOR.replace("  1\n}", "  2\n}"),
        ] {
            assert_ne!(derive_operator(&source).unwrap(), original);
        }
        assert!(derive_operator(&OPERATOR.replace("list.find", "list.last")).is_err());
    }

    #[test]
    fn derives_prefix_matching_and_default_selection() {
        let original = derive_plan(PLAN).unwrap();
        assert_ne!(
            derive_plan(&PLAN.replace("|| string.starts_with", "&& string.starts_with")).unwrap(),
            original
        );
        assert_ne!(
            derive_plan(&PLAN.replace("True -> Changed", "True -> All")).unwrap(),
            original
        );
        assert!(derive_plan(&PLAN.replace("[mutant] ->", "[mutant, ..] ->")).is_err());
    }
}
