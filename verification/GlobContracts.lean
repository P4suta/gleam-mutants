/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived
import Lean.Elab.Tactic.Omega

open GlobDerived

theorem glob_empty_contract (path : List Glyph) : accepts [] path = decide (path = []) := by
  cases path <;> simp [accepts]

theorem globstar_matches_every_path (path : List Glyph) : accepts [.star, .star] path = true := by
  induction path with
  | nil => simp [accepts]
  | cons head rest ih => simp [accepts, ih]

theorem globstar_zero_directory (pattern path : List Glyph) (matched : accepts pattern path = true) :
    accepts (.star :: .star :: .slash :: pattern) path = true := by
  cases path <;> simp [accepts, matched]

theorem globstar_directory_boundary :
    accepts [.star, .star, .slash, .other [97]] [.other [98], .other [97]] = false := by
  simp [accepts, afterDirectory]

theorem glob_no_directory (pattern path : List Glyph)
    (clean : ∀ character ∈ path, character ≠ .slash) : afterDirectory pattern path = false := by
  induction path with
  | nil => simp [afterDirectory]
  | cons head rest ih =>
    have headClean := clean head (by simp)
    have restClean : ∀ character ∈ rest, character ≠ .slash := by
      intro character member
      exact clean character (by simp [member])
    simp [afterDirectory, headClean, ih restClean]

theorem globstar_directory_contract (pattern path : List Glyph)
    (clean : ∀ character ∈ path, character ≠ .slash) :
    accepts (.star :: .star :: .slash :: pattern) path = accepts pattern path := by
  cases path <;> simp [accepts, glob_no_directory _ _ clean]

theorem glob_question_contract (character : Glyph) :
    accepts [.question] [character] = decide (character ≠ .slash) := by
  cases character <;> simp [accepts]

theorem glob_star_cannot_cross_slash (before after : List Glyph)
    (clean : ∀ character ∈ before, character ≠ .slash) :
    accepts [.star] (before ++ .slash :: after) = false := by
  induction before with
  | nil => simp [accepts]
  | cons head rest ih =>
    have headClean := clean head (by simp)
    have restClean : ∀ character ∈ rest, character ≠ .slash := by
      intro character member
      exact clean character (by simp [member])
    simp [accepts, headClean, ih restClean]

theorem glob_exclusion_priority (path : List Glyph) (includes excludes : List (List Glyph))
    (excluded : excludes.any (fun pattern => accepts pattern path) = true) :
    included path includes excludes = false := by simp [included, excluded]

theorem glob_inclusion_required (path : List Glyph) (excludes : List (List Glyph)) :
    included path [] excludes = false := by rfl

#print axioms glob_empty_contract
#print axioms globstar_matches_every_path
#print axioms globstar_zero_directory
#print axioms globstar_directory_boundary
#print axioms glob_no_directory
#print axioms globstar_directory_contract
#print axioms glob_question_contract
#print axioms glob_star_cannot_cross_slash
#print axioms glob_exclusion_priority
#print axioms glob_inclusion_required
