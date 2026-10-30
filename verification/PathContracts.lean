/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived
import Lean.Elab.Tactic.Omega

open PathDerived

def CanonicalSegment (value : List Nat) : Prop :=
  value ≠ [] ∧ value ≠ [46] ∧ value ≠ [46, 46]

theorem path_native_posix (value : List Nat) : from_native value false = value := by rfl

theorem path_native_idempotent (value : List Nat) (windows : Bool) :
    from_native (from_native value windows) windows = from_native value windows := by
  have replacement : (fun c : Nat => if c = 92 then 47 else c) ∘
      (fun c : Nat => if c = 92 then 47 else c) = (fun c : Nat => if c = 92 then 47 else c) := by
    funext character
    by_cases slash : character = 92 <;> simp [slash]
  cases windows <;> simp [from_native, List.map_map, replacement]

theorem path_step_contract (stack : List (List Nat)) (segment : List Nat) :
    step stack segment = if segment = [] ∨ segment = [46] then stack
      else if segment = [46, 46] then stack.drop 1 else segment :: stack := by rfl

theorem path_step_canonical (stack : List (List Nat)) (segment : List Nat)
    (clean : ∀ part ∈ stack, CanonicalSegment part) :
    ∀ part ∈ step stack segment, CanonicalSegment part := by
  by_cases ignored : segment = [] ∨ segment = [46]
  · simpa [step, ignored] using clean
  · by_cases parent : segment = [46, 46]
    · rw [step, if_neg ignored, if_pos parent]
      cases stack with
      | nil => simp
      | cons head rest =>
        intro part member
        exact clean part (by simp_all)
    · rw [step, if_neg ignored, if_neg parent]
      intro part member
      rcases List.mem_cons.mp member with same | member
      · subst part
        exact ⟨fun empty => ignored (.inl empty), fun dot => ignored (.inr dot), parent⟩
      · exact clean part member

theorem path_fold_canonical (segments stack : List (List Nat))
    (clean : ∀ part ∈ stack, CanonicalSegment part) :
    ∀ part ∈ segments.foldl step stack, CanonicalSegment part := by
  induction segments generalizing stack with
  | nil => exact clean
  | cons head rest ih => exact ih (step stack head) (path_step_canonical stack head clean)

theorem path_segments_canonical (segments : List (List Nat)) :
    ∀ part ∈ normalizeSegments segments, CanonicalSegment part := by
  have clean := path_fold_canonical segments [] (by simp)
  simpa only [normalizeSegments, List.mem_reverse] using clean

theorem path_fold_clean (segments stack : List (List Nat))
    (clean : ∀ part ∈ segments, CanonicalSegment part) :
    segments.foldl step stack = segments.reverse ++ stack := by
  induction segments generalizing stack with
  | nil => rfl
  | cons head rest ih =>
    have headClean := clean head (by simp)
    have restClean : ∀ part ∈ rest, CanonicalSegment part := by
      intro part member
      exact clean part (by simp [member])
    simp only [List.foldl_cons]
    have push : step stack head = head :: stack := by
      rcases headClean with ⟨empty, dot, parent⟩
      simp [step, empty, dot, parent]
    rw [push, ih _ restClean]
    simp

theorem path_clean_fixed_point (segments : List (List Nat))
    (clean : ∀ part ∈ segments, CanonicalSegment part) : normalizeSegments segments = segments := by
  unfold normalizeSegments
  rw [path_fold_clean segments [] clean]
  simp

theorem path_segments_idempotent (segments : List (List Nat)) :
    normalizeSegments (normalizeSegments segments) = normalizeSegments segments := by
  exact path_clean_fixed_point _ (path_segments_canonical segments)

theorem path_join_contract (left right : List Nat) :
    join left right = if left = [] then right else if right = [] then left else left ++ [47] ++ right := by rfl

theorem path_posix_root (rest : List (List Nat)) : rootParts ([] :: rest) false = ([47], rest) := by
  unfold rootParts
  split <;> simp_all

theorem path_unc_root (server share : List Nat) (rest : List (List Nat)) :
    rootParts ([] :: [] :: server :: share :: rest) true =
      ([47, 47] ++ server ++ [47] ++ share ++ [47], rest) := by rfl

theorem path_drive_root (drive : List Nat) (rest : List (List Nat)) (nonempty : drive ≠ []) :
    rootParts (drive :: rest) true = (drive ++ [47], rest) := by
  cases drive <;> simp_all [rootParts]

theorem path_root_clamps_parents : normalizeSegments [[46, 46], [46, 46]] = [] := by rfl

theorem path_root_clamps_every_parent (count : Nat) :
    normalizeSegments (List.replicate count [46, 46]) = [] := by
  have folded : (List.replicate count [46, 46]).foldl step [] = [] := by
    induction count with
    | zero => rfl
    | succ previous ih => simpa [List.replicate_succ, List.foldl_cons, step] using ih
  simpa [normalizeSegments] using congrArg List.reverse folded

#print axioms path_native_posix
#print axioms path_native_idempotent
#print axioms path_step_contract
#print axioms path_step_canonical
#print axioms path_fold_canonical
#print axioms path_segments_canonical
#print axioms path_fold_clean
#print axioms path_clean_fixed_point
#print axioms path_segments_idempotent
#print axioms path_join_contract
#print axioms path_posix_root
#print axioms path_unc_root
#print axioms path_drive_root
#print axioms path_root_clamps_parents
#print axioms path_root_clamps_every_parent
