/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived
import Lean.Elab.Tactic.Omega

open OutcomeDerived ScoreDerived

theorem score_partition (values : List Outcome) :
    count values (fun value => decide (value = .killed)) +
    count values (fun value => decide (value = .timedOut)) +
    count values (fun value => decide (value = .survived)) +
    count values (fun value => match value with | .testError _ => true | _ => false) =
      Int.ofNat values.length := by
  induction values with
  | nil => rfl
  | cons head rest ih =>
    cases head <;> simp_all [count] <;> omega

theorem score_error_count (values : List Outcome) :
    (calculate values).errors = count values
      (fun value => match value with | .testError _ => true | _ => false) := by
  have partition := score_partition values
  unfold calculate
  simp only
  omega

theorem score_nonnegative (values : List Outcome) :
    0 ≤ (calculate values).total ∧ 0 ≤ (calculate values).killed ∧
    0 ≤ (calculate values).timed_out ∧ 0 ≤ (calculate values).survived ∧
    0 ≤ (calculate values).errors := by
  have nonnegative (predicate : Outcome → Bool) : 0 ≤ count values predicate := by
    unfold count
    exact Int.ofNat_zero_le _
  refine ⟨?_, nonnegative _, nonnegative _, nonnegative _, ?_⟩
  · unfold calculate
    simp only
    have killed := nonnegative (fun value => decide (value = .killed))
    have timed := nonnegative (fun value => decide (value = .timedOut))
    have survived := nonnegative (fun value => decide (value = .survived))
    omega
  · rw [score_error_count]
    exact nonnegative _

theorem score_count_conservation (values : List Outcome) :
    (calculate values).total + (calculate values).errors = Int.ofNat values.length := by
  unfold calculate
  simp only
  omega

theorem score_valid_count (values : List Outcome) :
    (calculate values).total = (calculate values).killed +
      (calculate values).timed_out + (calculate values).survived := by rfl

theorem score_detected_count (values : List Outcome) :
    (calculate values).killed + (calculate values).timed_out =
      count values detected := by
  induction values with
  | nil => rfl
  | cons head rest ih =>
    cases head <;> simp_all [calculate, count, detected, List.filter_cons] <;> omega

theorem score_zero_denominator (values : List Outcome) :
    (calculate values).total = 0 → (calculate values).percent = .zero := by
  unfold calculate
  simp only
  intro zero
  simp [zero]

theorem score_ratio_contract (values : List Outcome) :
    (calculate values).total ≠ 0 →
      (calculate values).percent = .divideMultiply
        ((calculate values).killed + (calculate values).timed_out)
        (calculate values).total 100 := by
  unfold calculate
  simp only
  intro nonzero
  simp [nonzero]

theorem score_ratio_bounds (values : List Outcome) :
    (calculate values).total ≠ 0 →
      0 < (calculate values).total ∧
      0 ≤ (calculate values).killed + (calculate values).timed_out ∧
      (calculate values).killed + (calculate values).timed_out ≤ (calculate values).total := by
  have nonnegative := score_nonnegative values
  have total := score_valid_count values
  omega

theorem policy_strict_contract (override : Option Bool) :
    PolicyDerived.strict override = override.getD false := by
  cases override <;> rfl

theorem policy_exit_contract (errors : Int) (override : Option Bool) (below : Bool) :
    PolicyDerived.code errors override below =
      if 0 < errors then 2
      else if override.getD false && below then 1 else 0 := by
  unfold PolicyDerived.code
  rw [policy_strict_contract]
  by_cases failed : 0 < errors <;>
    cases (override.getD false && below) <;> simp [failed]

theorem policy_error_priority (errors : Int) (override : Option Bool) (below : Bool)
    (failed : 0 < errors) : PolicyDerived.code errors override below = 2 := by
  rw [policy_exit_contract]
  simp [failed]

theorem policy_non_strict (errors : Int) (below : Bool) (clean : errors ≤ 0) :
    PolicyDerived.code errors (some false) below = 0 := by
  rw [policy_exit_contract]
  have notFailed : ¬0 < errors := by omega
  simp [notFailed]

theorem policy_strict_threshold (below : Bool) :
    PolicyDerived.code 0 (some true) below = if below then 1 else 0 := by
  rw [policy_exit_contract]
  cases below <;> rfl

#print axioms score_partition
#print axioms score_nonnegative
#print axioms score_error_count
#print axioms score_count_conservation
#print axioms score_valid_count
#print axioms score_detected_count
#print axioms score_zero_denominator
#print axioms score_ratio_contract
#print axioms score_ratio_bounds
#print axioms policy_strict_contract
#print axioms policy_exit_contract
#print axioms policy_error_priority
#print axioms policy_non_strict
#print axioms policy_strict_threshold
