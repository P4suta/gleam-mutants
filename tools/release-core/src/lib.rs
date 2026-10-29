// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#![no_std]
#![deny(clippy::panic, clippy::unwrap_used, clippy::expect_used)]

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(kani, derive(kani::Arbitrary))]
pub enum Existing {
    Missing,
    Matching,
    Conflicting,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WritePlan {
    Create,
    Reuse,
    Refuse,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(kani, derive(kani::Arbitrary))]
pub enum CiRecord {
    Missing,
    Suppressed,
    Present,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CiAction {
    Dispatch,
    Keep,
}

pub fn proposal_ci(record: CiRecord) -> CiAction {
    match record {
        CiRecord::Missing | CiRecord::Suppressed => CiAction::Dispatch,
        CiRecord::Present => CiAction::Keep,
    }
}

pub fn plan_write(verified: bool, existing: Existing) -> WritePlan {
    match (verified, existing) {
        (false, Existing::Missing | Existing::Matching | Existing::Conflicting)
        | (true, Existing::Conflicting) => WritePlan::Refuse,
        (true, Existing::Missing) => WritePlan::Create,
        (true, Existing::Matching) => WritePlan::Reuse,
    }
}

pub fn can_finalize(identity: bool, assets: bool, hex: bool, npm: bool, draft: bool) -> bool {
    identity && assets && hex && npm && draft
}

#[derive(Clone, Copy, Debug)]
#[cfg_attr(kani, derive(kani::Arbitrary))]
pub struct RuntimeCounts {
    pub total: u64,
    pub killed: u64,
    pub survived: u64,
    pub timed_out: u64,
    pub errors: u64,
    pub executed: u64,
    pub results: u64,
    pub compile_errors: u64,
    pub rejected: u64,
}

pub fn conclusive_counts(m: RuntimeCounts) -> bool {
    m.total != 0
        && m.timed_out == 0
        && m.errors == 0
        && m.killed.checked_add(m.survived) == Some(m.total)
        && m.results == m.total
        && m.executed == m.total
        && m.compile_errors == m.rejected
}

#[cfg(kani)]
mod proofs {
    use super::{Existing, WritePlan, can_finalize, plan_write};

    #[kani::proof]
    fn proposal_ci_distinguishes_suppression_from_execution() {
        let record: super::CiRecord = kani::any();
        let action = super::proposal_ci(record);
        assert!((action == super::CiAction::Dispatch) == (record != super::CiRecord::Present));
        assert!((action == super::CiAction::Keep) == (record == super::CiRecord::Present));
    }

    #[kani::proof]
    fn runtime_counts_exclude_empty_and_inconclusive_measurements() {
        let m: super::RuntimeCounts = kani::any();
        let arithmetic = m.survived <= m.total && m.killed == m.total - m.survived;
        let requirements = m.total > 0
            && arithmetic
            && m.timed_out == 0
            && m.errors == 0
            && m.executed == m.total
            && m.results == m.total
            && m.compile_errors == m.rejected;
        assert!(super::conclusive_counts(m) == requirements);
    }

    #[kani::proof]
    fn writes_preserve_verified_outputs() {
        let verified: bool = kani::any();
        let existing: Existing = kani::any();
        let plan = plan_write(verified, existing);
        assert!((plan == WritePlan::Create) == (verified && existing == Existing::Missing));
        assert!((plan == WritePlan::Reuse) == (verified && existing == Existing::Matching));
        assert!((plan == WritePlan::Refuse) == (!verified || existing == Existing::Conflicting));
    }

    #[kani::proof]
    fn finalization_requires_every_obligation() {
        let identity: bool = kani::any();
        let assets: bool = kani::any();
        let hex: bool = kani::any();
        let npm: bool = kani::any();
        let draft: bool = kani::any();
        if can_finalize(identity, assets, hex, npm, draft) {
            assert!(identity);
            assert!(assets);
            assert!(hex);
            assert!(npm);
            assert!(draft);
        } else {
            assert!(!identity || !assets || !hex || !npm || !draft);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Existing, WritePlan, can_finalize, plan_write};

    #[test]
    fn only_executed_or_pending_ci_prevents_a_dispatch() {
        assert_eq!(
            super::proposal_ci(super::CiRecord::Missing),
            super::CiAction::Dispatch
        );
        assert_eq!(
            super::proposal_ci(super::CiRecord::Suppressed),
            super::CiAction::Dispatch
        );
        assert_eq!(
            super::proposal_ci(super::CiRecord::Present),
            super::CiAction::Keep
        );
    }

    #[test]
    fn checked_outputs_can_be_reused_and_conflicts_are_never_overwritten() {
        assert_eq!(plan_write(true, Existing::Missing), WritePlan::Create);
        assert_eq!(plan_write(true, Existing::Matching), WritePlan::Reuse);
        assert_eq!(plan_write(true, Existing::Conflicting), WritePlan::Refuse);
        for existing in [Existing::Missing, Existing::Matching, Existing::Conflicting] {
            assert_eq!(plan_write(false, existing), WritePlan::Refuse);
        }
    }

    #[test]
    fn every_finalization_requirement_is_indispensable() {
        let values = [false, true];
        for identity in values {
            for assets in values {
                for hex in values {
                    for npm in values {
                        for draft in values {
                            let allowed = can_finalize(identity, assets, hex, npm, draft);
                            assert_eq!(
                                allowed,
                                [identity, assets, hex, npm, draft].iter().all(|v| *v)
                            );
                        }
                    }
                }
            }
        }
    }
}
