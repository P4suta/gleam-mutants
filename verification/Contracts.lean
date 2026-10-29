/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived

theorem jobs_contract (value : Int) :
    Derived.valid_jobs value = decide (1 ≤ value ∧ value ≤ 32) := by rfl

theorem timeout_contract (value : Int) :
    Derived.valid_timeout value = decide (100 ≤ value ∧ value ≤ 86400000) := by rfl

theorem interruption_contract (value : Int) :
    Derived.interrupted value = decide (value = 130 ∨ value = 143) := by rfl

#print axioms jobs_contract
#print axioms timeout_contract
#print axioms interruption_contract
