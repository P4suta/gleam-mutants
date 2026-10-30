/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived
import Lean.Elab.Tactic.Omega

open PathDerived

theorem path_split_component (value : List Nat) (clean : ∀ character ∈ value, character ≠ 47) :
    splitSlash value = [value] := by
  induction value with
  | nil => rfl
  | cons head rest ih =>
    have headClean := clean head (by simp)
    have restClean : ∀ character ∈ rest, character ≠ 47 := by
      intro character member
      exact clean character (by simp [member])
    simp [splitSlash, headClean, ih restClean]

theorem path_drive_alphabet (letter : Nat) :
    driveRoot [letter, 58] = true ↔ ((65 ≤ letter ∧ letter ≤ 90) ∨ (97 ≤ letter ∧ letter ≤ 122)) := by
  simp [driveRoot]
  omega

theorem path_parent_parts_posix (child : List Nat) : parentParts [[], child] = [47] := by
  cases child <;> rfl

theorem path_parent_posix_component (child : List Nat)
    (clean : ∀ character ∈ child, character ≠ 47) : parent (47 :: child) = [47] := by
  have pieces : splitSlash (47 :: child) = [[], child] := by
    simp [splitSlash, path_split_component child clean]
  simp only [parent, List.cons_ne_nil, ↓reduceIte, pieces, path_parent_parts_posix]

theorem path_parent_parts_drive (letter : Nat) (child : List Nat)
    (valid : (65 ≤ letter ∧ letter ≤ 90) ∨ (97 ≤ letter ∧ letter ≤ 122)) :
    parentParts [[letter, 58], child] = [letter, 58, 47] := by
  have drive : driveRoot [letter, 58] = true := (path_drive_alphabet letter).mpr valid
  cases child <;> simp [parentParts, parentWindows, drive, rootParts, parentSegments, joinSlash]

theorem path_parent_parts_unc (server share child : List Nat)
    (serverPresent : server ≠ []) (sharePresent : share ≠ []) :
    parentParts [[], [], server, share, child] = [47, 47] ++ server ++ [47] ++ share ++ [47] := by
  cases child <;> simp [parentParts, parentWindows, serverPresent, sharePresent, rootParts, parentSegments, joinSlash]

theorem path_parent_unc_root (server share : List Nat)
    (serverPresent : server ≠ []) (sharePresent : share ≠ []) :
    parentParts [[], [], server, share] = [47, 47] ++ server ++ [47] ++ share ++ [47] := by
  simp [parentParts, parentWindows, serverPresent, sharePresent, rootParts, parentSegments, joinSlash]

theorem path_drop_empty_clean (segments : List (List Nat))
    (clean : ∀ segment ∈ segments, segment ≠ []) :
    segments.dropWhile (fun segment => decide (segment = [])) = segments := by
  cases segments with
  | nil => rfl
  | cons head rest =>
    have headClean := clean head (by simp)
    simp [List.dropWhile, headClean]

theorem path_parent_segment_progress (segments : List (List Nat))
    (clean : ∀ segment ∈ segments, segment ≠ []) (nonempty : segments ≠ []) :
    (parentSegments segments).length + 1 = segments.length := by
  have reversedClean : ∀ segment ∈ segments.reverse, segment ≠ [] := by simpa using clean
  have positive : 0 < segments.length := by cases segments <;> simp_all
  unfold parentSegments
  rw [path_drop_empty_clean _ reversedClean]
  simp only [List.length_reverse, List.length_drop]
  omega

theorem path_parent_posix_root : PathDerived.parent [47] = [47] := by rfl

theorem path_parent_empty_relative : PathDerived.parent [] = [] := by rfl

#print axioms path_parent_posix_root
#print axioms path_parent_empty_relative
#print axioms path_split_component
#print axioms path_drive_alphabet
#print axioms path_parent_parts_posix
#print axioms path_parent_posix_component
#print axioms path_parent_parts_drive
#print axioms path_parent_parts_unc
#print axioms path_parent_unc_root
#print axioms path_drop_empty_clean
#print axioms path_parent_segment_progress
