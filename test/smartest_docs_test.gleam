// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/result
import gleam/string
import simplifile

pub fn smartest_guide_is_linked_and_registered_as_package_documentation_test() {
  let readme = simplifile.read("README.md") |> result.unwrap("")
  let config = simplifile.read("gleam.toml") |> result.unwrap("")
  assert string.contains(readme, "Smartest")
  assert string.contains(readme, "docs/smartest.md")
  assert string.contains(config, "title = \"Smartest\"")
  assert string.contains(config, "source = \"docs/smartest.md\"")
}

pub fn smartest_guide_documents_the_evidence_loop_and_offline_trust_model_test() {
  let guide = simplifile.read("docs/smartest.md") |> result.unwrap("")
  assert string.contains(guide, "UnjudgedDivergence")
  assert string.contains(guide, "NotDistinguishedWithinBudget")
  assert string.contains(guide, "Provisional")
  assert string.contains(guide, "Trusted")
  assert string.contains(guide, "smartest accept")
  assert string.contains(guide, "No network, AI service, or telemetry")
}

pub fn smartest_guide_documents_native_techniques_modes_and_capabilities_test() {
  let guide = simplifile.read("docs/smartest.md") |> result.unwrap("")
  assert string.contains(guide, "smartest/property")
  assert string.contains(guide, "smartest/fuzz")
  assert string.contains(guide, "smartest/solver")
  assert string.contains(guide, "smartest/transcript")
  assert string.contains(guide, "smartest watch")
  assert string.contains(guide, "smartest ci")
  assert string.contains(guide, "Network")
  assert string.contains(guide, "Subprocess")
}

pub fn smartest_guide_makes_red_green_refactor_the_phase_contract_test() {
  let guide = simplifile.read("docs/smartest.md") |> result.unwrap("")
  assert string.contains(guide, "## TDD development contract")
  assert string.contains(guide, "RED")
  assert string.contains(guide, "GREEN")
  assert string.contains(guide, "refactor")
  assert string.contains(guide, "Every development phase")
}
