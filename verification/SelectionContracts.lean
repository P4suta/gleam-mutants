/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived
import Lean.Elab.Tactic.Omega

theorem operator_inventory_complete (operator : OperatorDerived.Operator) :
    operator ∈ OperatorDerived.all := by
  cases operator <;> decide

theorem operator_inventory_unique : OperatorDerived.all.Nodup := by decide

theorem operator_name_round_trip (operator : OperatorDerived.Operator) :
    OperatorDerived.from_name (OperatorDerived.name operator) = some operator := by
  cases operator <;> rfl

theorem operator_names_injective (a b : OperatorDerived.Operator) :
    OperatorDerived.name a = OperatorDerived.name b ↔ a = b := by
  cases a <;> cases b <;> simp [OperatorDerived.name]

theorem operator_version_contract (operator : OperatorDerived.Operator) :
    OperatorDerived.version operator = 1 := by rfl

def ExpectedOperatorName : OperatorDerived.Operator → String
  | .BooleanLiteral => "boolean-literal"
  | .BooleanNegation => "boolean-negation"
  | .BooleanConnective => "boolean-connective"
  | .Equality => "equality"
  | .ComparisonBoundary => "comparison-boundary"
  | .IntegerArithmetic => "integer-arithmetic"
  | .FloatArithmetic => "float-arithmetic"
  | .IntegerNeutral => "integer-neutral"
  | .FloatNeutral => "float-neutral"
  | .StringNeutral => "string-neutral"
  | .ListNeutral => "list-neutral"
  | .OptionNeutral => "option-neutral"
  | .PipelineStageDeletion => "pipeline-stage-deletion"
  | .ConcatenationOperand => "concatenation-operand"
  | .IntegerNegation => "integer-negation"

theorem operator_name_contract (operator : OperatorDerived.Operator) :
    OperatorDerived.name operator = (ExpectedOperatorName operator).toList.map Char.toNat := by
  cases operator <;> rfl

open PlanDerived

theorem plan_all_contract (values : List Mutant) :
    build values false none = .ok ⟨.all, values⟩ := by rfl

theorem plan_changed_contract (values : List Mutant) :
    build values true none = .ok ⟨.changed, values⟩ := by rfl

theorem plan_match_contract (needle : List Nat) (mutant : Mutant) :
    accepts needle mutant = (needle.isPrefixOf mutant.id || needle.isPrefixOf mutant.display_id) := by rfl

theorem plan_missing_contract (values : List Mutant) (changed : Bool) (needle : List Nat) :
    build values changed (some needle) = .error (.noMatch needle) ↔
      values.filter (accepts needle) = [] := by
  simp only [build]
  cases selected : values.filter (accepts needle) with
  | nil => simp [selected]
  | cons head rest => cases rest <;> simp [selected]

theorem plan_unique_contract (values : List Mutant) (changed : Bool) (needle : List Nat) (mutant : Mutant) :
    build values changed (some needle) = .ok ⟨.single needle, [mutant]⟩ ↔
      values.filter (accepts needle) = [mutant] := by
  simp only [build]
  cases selected : values.filter (accepts needle) with
  | nil => simp [selected]
  | cons head rest => cases rest <;> simp [selected]

theorem plan_ambiguous_contract (values : List Mutant) (changed : Bool) (needle : List Nat) :
    build values changed (some needle) = .error (.ambiguous needle) ↔
      2 ≤ (values.filter (accepts needle)).length := by
  simp only [build]
  cases selected : values.filter (accepts needle) with
  | nil => simp [selected]
  | cons head rest => cases rest <;> simp [selected]

theorem plan_selected_membership (values : List Mutant) (needle : List Nat) (mutant : Mutant) :
    mutant ∈ values.filter (accepts needle) ↔
      mutant ∈ values ∧ (needle.isPrefixOf mutant.id = true ∨ needle.isPrefixOf mutant.display_id = true) := by
  simp [accepts]

theorem plan_filter_preserves_order (values : List Mutant) (needle : List Nat) :
    (values.filter (accepts needle)).Sublist values := by
  exact List.filter_sublist

theorem plan_accessor_contract (plan : Plan) : mutants plan = plan.mutants := by rfl

theorem plan_modes_contract (values : List Mutant) (needle : List Nat) :
    mode ⟨.all, values⟩ = [97, 108, 108] ∧
    mode ⟨.changed, values⟩ = [99, 104, 97, 110, 103, 101, 100] ∧
    mode ⟨.single needle, values⟩ = [109, 117, 116, 97, 110, 116] := by
  exact ⟨rfl, rfl, rfl⟩

#print axioms operator_inventory_complete
#print axioms operator_inventory_unique
#print axioms operator_name_round_trip
#print axioms operator_names_injective
#print axioms operator_version_contract
#print axioms operator_name_contract
#print axioms plan_all_contract
#print axioms plan_changed_contract
#print axioms plan_match_contract
#print axioms plan_missing_contract
#print axioms plan_unique_contract
#print axioms plan_ambiguous_contract
#print axioms plan_selected_membership
#print axioms plan_filter_preserves_order
#print axioms plan_accessor_contract
#print axioms plan_modes_contract
