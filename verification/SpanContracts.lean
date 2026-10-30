/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived
import Lean.Elab.Tactic.Omega

open SpanDerived

def ValidSpan (span : Span) : Prop := 0 ≤ span.start ∧ span.start ≤ span.end

def BeforeSpan (a b : Span) : Prop :=
  a.start < b.start ∨ (a.start = b.start ∧ b.end < a.end)

theorem span_constructor_contract (start finish : Int) :
    new start finish =
      if start < 0 then .error .negativeStart
      else if finish < start then .error .endBeforeStart
      else .ok ⟨start, finish⟩ := by
  unfold new
  by_cases first : start < 0 <;> by_cases second : finish < start <;>
    simp [first, second]

theorem span_constructor_valid (start finish : Int) (span : Span) :
    new start finish = .ok span ↔
      span = ⟨start, finish⟩ ∧ 0 ≤ start ∧ start ≤ finish := by
  cases span
  rw [span_constructor_contract]
  by_cases first : start < 0 <;> by_cases second : finish < start <;>
    simp [first, second] <;> omega

theorem span_assertion_contract (start finish : Int) :
    unsafe_new start finish =
      if 0 ≤ start ∧ start ≤ finish then .returned ⟨start, finish⟩
      else .assertionFailed := by
  unfold unsafe_new
  rw [span_constructor_contract]
  by_cases first : start < 0 <;> by_cases second : finish < start <;>
    simp [first, second] <;> omega

theorem span_accessors_contract (span : Span) :
    SpanDerived.start span = span.start ∧ SpanDerived.end span = span.end := by
  exact ⟨rfl, rfl⟩

theorem span_length_contract (span : Span) :
    length span = span.end - span.start := by rfl

theorem span_length_nonnegative (span : Span) (valid : ValidSpan span) :
    0 ≤ length span := by
  unfold length ValidSpan at *
  omega

theorem span_equal_contract (a b : Span) : equal a b = true ↔ a = b := by
  cases a
  cases b
  simp [equal]

theorem span_contains_contract (a b : Span) :
    contains a b = true ↔ a.start ≤ b.start ∧ b.end ≤ a.end := by
  simp [contains]

theorem span_contains_reflexive (a : Span) : contains a a = true := by
  simp [contains]

theorem span_contains_transitive (a b c : Span)
    (ab : contains a b = true) (bc : contains b c = true) :
    contains a c = true := by
  simp only [span_contains_contract] at *
  omega

theorem span_contains_antisymmetric (a b : Span)
    (forward : contains a b = true) (backward : contains b a = true) : a = b := by
  cases a
  cases b
  simp only [span_contains_contract] at *
  congr <;> omega

theorem span_strict_contains_contract (a b : Span) :
    strictly_contains a b = true ↔ contains a b = true ∧ a ≠ b := by
  cases a
  cases b
  simp [strictly_contains, equal] <;> omega

theorem span_strict_contains_irreflexive (a : Span) :
    strictly_contains a a = false := by
  simp [strictly_contains, equal]

theorem span_overlap_contract (a b : Span) :
    overlaps a b = true ↔ a.start < b.end ∧ b.start < a.end := by
  simp [overlaps]

theorem span_overlap_symmetric (a b : Span) : overlaps a b = overlaps b a := by
  exact Bool.and_comm _ _

theorem span_overlap_intersection (a b : Span)
    (aNonempty : a.start < a.end) (bNonempty : b.start < b.end) :
    overlaps a b = true ↔ max a.start b.start < min a.end b.end := by
  simp only [span_overlap_contract]
  omega

theorem span_partial_overlap_contract (a b : Span) :
    partially_overlaps a b = true ↔
      overlaps a b = true ∧ contains a b = false ∧ contains b a = false := by
  simp [partially_overlaps, and_assoc]

theorem span_partial_overlap_symmetric (a b : Span) :
    partially_overlaps a b = partially_overlaps b a := by
  unfold partially_overlaps
  rw [span_overlap_symmetric]
  cases overlaps b a <;> cases contains a b <;> cases contains b a <;> rfl

theorem span_compare_equal (a b : Span) : SpanDerived.compare a b = .eq ↔ a = b := by
  cases a
  cases b
  unfold SpanDerived.compare
  split <;> simp_all <;> omega

theorem span_compare_before (a b : Span) : SpanDerived.compare a b = .lt ↔ BeforeSpan a b := by
  unfold SpanDerived.compare BeforeSpan
  split <;> simp_all <;> omega

theorem span_compare_after (a b : Span) : SpanDerived.compare a b = .gt ↔ BeforeSpan b a := by
  unfold SpanDerived.compare BeforeSpan
  split <;> simp_all <;> omega

theorem span_compare_transitive (a b c : Span)
    (ab : SpanDerived.compare a b = .lt) (bc : SpanDerived.compare b c = .lt) : SpanDerived.compare a c = .lt := by
  rw [span_compare_before] at *
  unfold BeforeSpan at *
  omega

theorem span_compare_total (a b : Span) :
    SpanDerived.compare a b = .lt ∨ a = b ∨ SpanDerived.compare b a = .lt := by
  rw [span_compare_before, span_compare_before]
  cases a
  cases b
  unfold BeforeSpan
  simp only [Span.mk.injEq]
  omega

theorem span_parent_before_child (a b : Span) (inside : strictly_contains a b = true) :
    SpanDerived.compare a b = .lt := by
  rw [span_strict_contains_contract] at inside
  rw [span_compare_before]
  rcases inside with ⟨contained, distinct⟩
  rw [span_contains_contract] at contained
  cases a
  cases b
  unfold BeforeSpan
  simp_all [SpanDerived.start, SpanDerived.end, Span.mk.injEq] <;> omega

#print axioms span_constructor_contract
#print axioms span_constructor_valid
#print axioms span_assertion_contract
#print axioms span_accessors_contract
#print axioms span_length_contract
#print axioms span_length_nonnegative
#print axioms span_equal_contract
#print axioms span_contains_contract
#print axioms span_contains_reflexive
#print axioms span_contains_transitive
#print axioms span_contains_antisymmetric
#print axioms span_strict_contains_contract
#print axioms span_strict_contains_irreflexive
#print axioms span_overlap_contract
#print axioms span_overlap_symmetric
#print axioms span_overlap_intersection
#print axioms span_partial_overlap_contract
#print axioms span_partial_overlap_symmetric
#print axioms span_compare_equal
#print axioms span_compare_before
#print axioms span_compare_after
#print axioms span_compare_transitive
#print axioms span_compare_total
#print axioms span_parent_before_child
