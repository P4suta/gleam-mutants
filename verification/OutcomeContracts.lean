/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived
import Lean.Elab.Tactic.Omega

open OutcomeDerived

def FirstError : List Outcome → Option (List Nat)
  | [] => none
  | .testError message :: _ => some message
  | _ :: rest => FirstError rest

theorem outcome_detected_contract (value : Outcome) :
    detected value = true ↔ value = .killed ∨ value = .timedOut := by
  cases value <;> simp [detected]

theorem outcome_detection_agrees (value : Outcome) : detected value = is_detected value := by
  cases value <;> rfl

theorem outcome_find_first_error (values : List Outcome) :
    values.find? isError = (FirstError values).map Outcome.testError := by
  induction values with
  | nil => rfl
  | cons value rest ih => cases value <;> simp_all [List.find?, isError, FirstError]

theorem outcome_any_membership (values : List Outcome) (target : Outcome) :
    values.any (fun item => decide (item = target)) = decide (target ∈ values) := by
  induction values with
  | nil => rfl
  | cons value rest ih =>
    rw [List.any_cons, ih]
    by_cases same : value = target
    · subst value
      simp
    · have other : target ≠ value := fun equality => same equality.symm
      simp [same, other]

theorem outcome_aggregate_contract (values : List Outcome) :
    aggregate values =
      if values = [] then .testError [110, 111, 32, 114, 117, 110, 116, 105, 109, 101, 32, 114, 101, 115, 117, 108, 116, 115]
      else match FirstError values with
        | some message => .testError message
        | none => if .survived ∈ values then .survived
          else if .timedOut ∈ values then .timedOut else .killed := by
  cases values with
  | nil => rfl
  | cons value rest =>
    simp only [aggregate, aggregate_nonempty, outcome_find_first_error, outcome_any_membership]
    cases FirstError (value :: rest) <;> simp

theorem outcome_error_payload_priority (earlier suffix : List Outcome) (message : List Nat)
    (clean : ∀ value ∈ earlier, isError value = false) :
    aggregate (earlier ++ .testError message :: suffix) = .testError message := by
  have first : (earlier ++ .testError message :: suffix).find? isError = some (.testError message) := by
    induction earlier with
    | nil => rfl
    | cons head rest ih =>
      have headClean := clean head (by simp)
      have restClean : ∀ earlier ∈ rest, isError earlier = false := by
        intro earlier member
        exact clean earlier (by simp [member])
      simp [headClean, ih restClean]
  cases earlier with
  | nil => rfl
  | cons head rest =>
    change aggregate_nonempty (head :: (rest ++ .testError message :: suffix)) = .testError message
    unfold aggregate_nonempty
    simp only [List.cons_append] at first
    rw [first]

theorem outcome_errors_are_not_detected (message : List Nat) :
    detected (.testError message) = false := by rfl

theorem outcome_empty_is_error : aggregate [] =
    .testError [110, 111, 32, 114, 117, 110, 116, 105, 109, 101, 32, 114, 101, 115, 117, 108, 116, 115] := by rfl

theorem outcome_runtime_names_injective (a b : Runtime) :
    runtime_name a = runtime_name b ↔ a = b := by
  cases a <;> cases b <;> simp [runtime_name]

theorem outcome_runtime_name_contract (value : Runtime) :
    runtime_name value = (match value with
      | .erlang => "erlang" | .node => "node" | .deno => "deno" | .bun => "bun").toList.map Char.toNat := by
  cases value <;> rfl

#print axioms outcome_detected_contract
#print axioms outcome_detection_agrees
#print axioms outcome_find_first_error
#print axioms outcome_any_membership
#print axioms outcome_aggregate_contract
#print axioms outcome_error_payload_priority
#print axioms outcome_errors_are_not_detected
#print axioms outcome_empty_is_error
#print axioms outcome_runtime_names_injective
#print axioms outcome_runtime_name_contract
