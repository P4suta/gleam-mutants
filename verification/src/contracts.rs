// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

pub const SOURCES: &[&str] = &[
    "src/gleam_mutants/core/limits.gleam",
    "src/gleam_mutants/core/filesystem_entry.gleam",
    "src/gleam_mutants/core/span.gleam",
    "src/gleam_mutants/core/outcome.gleam",
    "src/gleam_mutants/core/score.gleam",
    "src/gleam_mutants/core/exit_policy.gleam",
    "src/gleam_mutants/core/operator.gleam",
    "src/gleam_mutants/core/plan.gleam",
    "src/gleam_mutants/types.gleam",
    "src/gleam_mutants/core/path.gleam",
    "src/gleam_mutants/core/glob.gleam",
];

pub struct Suite {
    pub module: &'static str,
    pub theorems: &'static [&'static str],
    pub constructive: bool,
}

pub const SUITES: &[Suite] = &[
    Suite {
        module: "ParentContracts",
        constructive: false,
        theorems: &[
            "path_parent_posix_root",
            "path_parent_empty_relative",
            "path_split_component",
            "path_drive_alphabet",
            "path_parent_parts_posix",
            "path_parent_posix_component",
            "path_parent_parts_drive",
            "path_parent_parts_unc",
            "path_parent_unc_root",
            "path_drop_empty_clean",
            "path_parent_segment_progress",
        ],
    },
    Suite {
        module: "PathContracts",
        constructive: false,
        theorems: &[
            "path_native_posix",
            "path_native_idempotent",
            "path_step_contract",
            "path_step_canonical",
            "path_fold_canonical",
            "path_segments_canonical",
            "path_fold_clean",
            "path_clean_fixed_point",
            "path_segments_idempotent",
            "path_join_contract",
            "path_posix_root",
            "path_unc_root",
            "path_drive_root",
            "path_root_clamps_parents",
            "path_root_clamps_every_parent",
        ],
    },
    Suite {
        module: "GlobContracts",
        constructive: false,
        theorems: &[
            "glob_empty_contract",
            "globstar_matches_every_path",
            "globstar_zero_directory",
            "globstar_directory_boundary",
            "glob_no_directory",
            "globstar_directory_contract",
            "glob_question_contract",
            "glob_star_cannot_cross_slash",
            "glob_exclusion_priority",
            "glob_inclusion_required",
        ],
    },
    Suite {
        module: "SelectionContracts",
        constructive: false,
        theorems: &[
            "operator_inventory_complete",
            "operator_inventory_unique",
            "operator_name_round_trip",
            "operator_names_injective",
            "operator_version_contract",
            "operator_name_contract",
            "plan_all_contract",
            "plan_changed_contract",
            "plan_match_contract",
            "plan_missing_contract",
            "plan_unique_contract",
            "plan_ambiguous_contract",
            "plan_selected_membership",
            "plan_filter_preserves_order",
            "plan_accessor_contract",
            "plan_modes_contract",
        ],
    },
    Suite {
        module: "ScoringContracts",
        constructive: false,
        theorems: &[
            "score_partition",
            "score_nonnegative",
            "score_error_count",
            "score_count_conservation",
            "score_valid_count",
            "score_detected_count",
            "score_zero_denominator",
            "score_ratio_contract",
            "score_ratio_bounds",
            "policy_strict_contract",
            "policy_exit_contract",
            "policy_error_priority",
            "policy_non_strict",
            "policy_strict_threshold",
        ],
    },
    Suite {
        module: "Contracts",
        constructive: true,
        theorems: &[
            "jobs_contract",
            "timeout_contract",
            "interruption_contract",
            "unshared_file_contract",
            "compiler_rejection_contract",
            "filesystem_entry_contract",
        ],
    },
    Suite {
        module: "SpanContracts",
        constructive: false,
        theorems: &[
            "span_constructor_contract",
            "span_constructor_valid",
            "span_assertion_contract",
            "span_accessors_contract",
            "span_length_contract",
            "span_length_nonnegative",
            "span_equal_contract",
            "span_contains_contract",
            "span_contains_reflexive",
            "span_contains_transitive",
            "span_contains_antisymmetric",
            "span_strict_contains_contract",
            "span_strict_contains_irreflexive",
            "span_overlap_contract",
            "span_overlap_symmetric",
            "span_overlap_intersection",
            "span_partial_overlap_contract",
            "span_partial_overlap_symmetric",
            "span_compare_equal",
            "span_compare_before",
            "span_compare_after",
            "span_compare_transitive",
            "span_compare_total",
            "span_parent_before_child",
        ],
    },
    Suite {
        module: "OutcomeContracts",
        constructive: false,
        theorems: &[
            "outcome_detected_contract",
            "outcome_detection_agrees",
            "outcome_find_first_error",
            "outcome_any_membership",
            "outcome_aggregate_contract",
            "outcome_error_payload_priority",
            "outcome_errors_are_not_detected",
            "outcome_empty_is_error",
            "outcome_runtime_names_injective",
            "outcome_runtime_name_contract",
        ],
    },
];

pub fn check_axioms(suite: &Suite, output: &str) -> Result<(), String> {
    for theorem in suite.theorems {
        let prefix = format!("'{theorem}' ");
        let records: Vec<_> = output
            .lines()
            .filter_map(|line| line.strip_prefix(&prefix))
            .collect();
        let [record] = records.as_slice() else {
            return Err(format!(
                "missing or duplicated axiom inventory for {theorem}"
            ));
        };
        if *record == "does not depend on any axioms" {
            continue;
        }
        let axioms = record
            .strip_prefix("depends on axioms: [")
            .and_then(|text| text.strip_suffix(']'));
        if suite.constructive
            || axioms.is_none_or(|list| {
                list.is_empty()
                    || list.split(", ").any(|axiom| {
                        !["propext", "Classical.choice", "Quot.sound"].contains(&axiom)
                    })
            })
        {
            return Err(format!(
                "unapproved axiom dependencies for {theorem}: {record}"
            ));
        }
    }
    Ok(())
}

pub struct Control {
    pub name: &'static str,
    pub source: &'static str,
    pub original: &'static str,
    pub broken: &'static str,
    pub claim: &'static str,
}

pub const CONTROLS: &[Control] = &[
    Control {
        name: "globstar_directory_boundary",
        source: "glob.gleam",
        original: "case segment == \"/\"",
        broken: "case segment != \"/\"",
        claim: "GlobDerived.accepts [.star, .star, .slash, .other [97]] [.other [98], .other [97]] = false",
    },
    Control {
        name: "parent_retains_root",
        source: "path.gleam",
        original: "root <> string.join(parent_segments, \"/\")",
        broken: "\"\" <> string.join(parent_segments, \"/\")",
        claim: "PathDerived.parent [47] = [47]",
    },
    Control {
        name: "path_parent_pop",
        source: "path.gleam",
        original: "list.drop(reversed, 1)",
        broken: "list.drop(reversed, 2)",
        claim: "PathDerived.normalizeSegments [[65], [66], [46, 46]] = [[65]]",
    },
    Control {
        name: "path_unc_prefix",
        source: "path.gleam",
        original: "\"//\" <> server",
        broken: "\"/\" <> server",
        claim: "PathDerived.rootParts [[], [], [65], [66]] true = ([47, 47, 65, 47, 66, 47], [])",
    },
    Control {
        name: "glob_empty",
        source: "glob.gleam",
        original: "[], [] -> True",
        broken: "[], [] -> False",
        claim: "GlobDerived.accepts [] [] = true",
    },
    Control {
        name: "glob_slash_barrier",
        source: "glob.gleam",
        original: "\n        [segment, ..path_rest] if segment != \"/\"",
        broken: "\n        [segment, ..path_rest] if segment == \"/\"",
        claim: "GlobDerived.accepts [.star] [.slash] = false",
    },
    Control {
        name: "glob_exclusion",
        source: "glob.gleam",
        original: "&& !list.any",
        broken: "|| !list.any",
        claim: "GlobDerived.included [] [[]] [[]] = false",
    },
    Control {
        name: "operator_version",
        source: "operator.gleam",
        original: "  1\n}",
        broken: "  2\n}",
        claim: "OperatorDerived.version .Equality = 1",
    },
    Control {
        name: "operator_name_collision",
        source: "operator.gleam",
        original: "\"equality\"",
        broken: "\"integer-neutral\"",
        claim: "OperatorDerived.from_name (OperatorDerived.name .IntegerNeutral) = some .IntegerNeutral",
    },
    Control {
        name: "plan_changed_mode",
        source: "plan.gleam",
        original: "True -> Changed",
        broken: "True -> All",
        claim: "PlanDerived.build [] true none = .ok ⟨.changed, []⟩",
    },
    Control {
        name: "plan_display_prefix",
        source: "plan.gleam",
        original: "|| string.starts_with",
        broken: "&& string.starts_with",
        claim: "PlanDerived.build [⟨[65], [66]⟩] false (some [66]) = .ok ⟨.single [66], [⟨[65], [66]⟩]⟩",
    },
    Control {
        name: "score_survivors_count",
        source: "score.gleam",
        original: "killed + timed_out + survived",
        broken: "killed + timed_out - survived",
        claim: "(ScoreDerived.calculate [.survived]).total = 1",
    },
    Control {
        name: "score_errors_count",
        source: "score.gleam",
        original: "list.length(outcomes) - total",
        broken: "list.length(outcomes) + total",
        claim: "(ScoreDerived.calculate [.killed]).errors = 0",
    },
    Control {
        name: "score_detection_numerator",
        source: "score.gleam",
        original: "int.to_float(killed + timed_out)",
        broken: "int.to_float(killed - timed_out)",
        claim: "(ScoreDerived.calculate [.timedOut]).percent = .divideMultiply 1 1 100",
    },
    Control {
        name: "score_empty_ratio",
        source: "score.gleam",
        original: "    0 -> 0.0",
        broken: "    1 -> 0.0",
        claim: "(ScoreDerived.calculate []).percent = .zero",
    },
    Control {
        name: "policy_default",
        source: "exit_policy.gleam",
        original: "None -> False",
        broken: "None -> True",
        claim: "PolicyDerived.code 0 none true = 0",
    },
    Control {
        name: "policy_errors",
        source: "exit_policy.gleam",
        original: "True, _ -> 2",
        broken: "True, _ -> 0",
        claim: "PolicyDerived.code 1 none false = 2",
    },
    Control {
        name: "policy_threshold",
        source: "exit_policy.gleam",
        original: "False, True -> 1",
        broken: "False, True -> 0",
        claim: "PolicyDerived.code 0 (some true) true = 1",
    },
    Control {
        name: "span_start_boundary",
        source: "span.gleam",
        original: "start < 0",
        broken: "start <= 0",
        claim: "SpanDerived.new 0 0 = .ok ⟨0, 0⟩",
    },
    Control {
        name: "span_end_boundary",
        source: "span.gleam",
        original: "end < start",
        broken: "end <= start",
        claim: "SpanDerived.new 1 1 = .ok ⟨1, 1⟩",
    },
    Control {
        name: "span_assertion",
        source: "span.gleam",
        original: "= new(start, end)",
        broken: "= new(end, start)",
        claim: "SpanDerived.unsafe_new 1 2 = .returned ⟨1, 2⟩",
    },
    Control {
        name: "span_start_accessor",
        source: "span.gleam",
        original: "  span.start\n}",
        broken: "  span.end\n}",
        claim: "SpanDerived.start ⟨1, 2⟩ = 1",
    },
    Control {
        name: "span_end_accessor",
        source: "span.gleam",
        original: "  span.end\n}",
        broken: "  span.start\n}",
        claim: "SpanDerived.end ⟨1, 2⟩ = 2",
    },
    Control {
        name: "span_length",
        source: "span.gleam",
        original: "span.end - span.start",
        broken: "span.start - span.end",
        claim: "SpanDerived.length ⟨1, 2⟩ = 1",
    },
    Control {
        name: "span_equal",
        source: "span.gleam",
        original: "a.start == b.start && a.end == b.end",
        broken: "a.start == b.start || a.end == b.end",
        claim: "SpanDerived.equal ⟨1, 2⟩ ⟨1, 3⟩ = false",
    },
    Control {
        name: "span_contains",
        source: "span.gleam",
        original: "outer.start <= inner.start",
        broken: "outer.start < inner.start",
        claim: "SpanDerived.contains ⟨1, 2⟩ ⟨1, 2⟩ = true",
    },
    Control {
        name: "span_strict_contains",
        source: "span.gleam",
        original: "&& !equal(outer, inner)",
        broken: "&& equal(outer, inner)",
        claim: "SpanDerived.strictly_contains ⟨1, 2⟩ ⟨1, 2⟩ = false",
    },
    Control {
        name: "span_overlap",
        source: "span.gleam",
        original: "a.start < b.end",
        broken: "a.start <= b.end",
        claim: "SpanDerived.overlaps ⟨1, 2⟩ ⟨0, 1⟩ = false",
    },
    Control {
        name: "span_partial_overlap",
        source: "span.gleam",
        original: "&& !contains(a, b)",
        broken: "|| !contains(a, b)",
        claim: "SpanDerived.partially_overlaps ⟨0, 1⟩ ⟨2, 3⟩ = false",
    },
    Control {
        name: "span_compare",
        source: "span.gleam",
        original: "True, _, _, _ -> Lt",
        broken: "True, _, _, _ -> Gt",
        claim: "SpanDerived.compare ⟨0, 1⟩ ⟨1, 2⟩ = .lt",
    },
    Control {
        name: "outcome_detection",
        source: "outcome.gleam",
        original: "Killed | TimedOut -> True",
        broken: "Killed | TimedOut -> False",
        claim: "OutcomeDerived.detected .timedOut = true",
    },
    Control {
        name: "outcome_error_priority",
        source: "outcome.gleam",
        original: "TestError(_) -> True",
        broken: "TestError(_) -> False",
        claim: "OutcomeDerived.aggregate [.survived, .testError [65], .testError [66]] = .testError [65]",
    },
    Control {
        name: "outcome_survival_priority",
        source: "outcome.gleam",
        original: "True -> Survived",
        broken: "True -> TimedOut",
        claim: "OutcomeDerived.aggregate [.killed, .survived, .timedOut] = .survived",
    },
    Control {
        name: "outcome_timeout_priority",
        source: "outcome.gleam",
        original: "True -> TimedOut",
        broken: "True -> Killed",
        claim: "OutcomeDerived.aggregate [.killed, .timedOut] = .timedOut",
    },
    Control {
        name: "outcome_detection_agreement",
        source: "outcome.gleam",
        original: "outcome == Killed ||",
        broken: "outcome == Killed &&",
        claim: "OutcomeDerived.is_detected .killed = true",
    },
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requires_every_theorem_and_rejects_untrusted_dependencies() {
        let suite = Suite {
            module: "Example",
            theorems: &["contract"],
            constructive: false,
        };
        assert!(check_axioms(&suite, "'contract' does not depend on any axioms").is_ok());
        assert!(
            check_axioms(
                &suite,
                "'contract' depends on axioms: [propext, Classical.choice, Quot.sound]"
            )
            .is_ok()
        );
        for output in [
            "",
            "'other' does not depend on any axioms",
            "'contract' depends on axioms: [sorryAx]",
            "'contract' depends on axioms: [Lean.ofReduceBool]",
            "'contract' depends on axioms: [custom]",
            "'contract' depends on axioms: []",
            "'contract' does not depend on any axioms\n'contract' does not depend on any axioms",
        ] {
            assert!(check_axioms(&suite, output).is_err(), "{output}");
        }
        let constructive = Suite {
            constructive: true,
            ..suite
        };
        assert!(check_axioms(&constructive, "'contract' depends on axioms: [propext]").is_err());
    }
}
