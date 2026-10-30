// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#![no_std]
#![deny(clippy::panic, clippy::unwrap_used, clippy::expect_used)]

use core::num::{NonZeroU32, NonZeroU64};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ControllerIdentity {
    run: NonZeroU64,
    attempt: NonZeroU32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControllerIdentityError {
    InvalidRun,
    InvalidAttempt,
    Empty,
}

impl ControllerIdentityError {
    pub fn message(self) -> &'static str {
        match self {
            Self::InvalidRun => "invalid controller run",
            Self::InvalidAttempt => "invalid controller attempt",
            Self::Empty => "controller identity is empty",
        }
    }
}

impl ControllerIdentity {
    pub fn new(run: u64, attempt: u32) -> Option<Self> {
        Some(Self {
            run: NonZeroU64::new(run)?,
            attempt: NonZeroU32::new(attempt)?,
        })
    }
    pub fn parse(run: &str, attempt: &str) -> Result<Self, ControllerIdentityError> {
        let run = run
            .parse()
            .map_err(|_| ControllerIdentityError::InvalidRun)?;
        let attempt = attempt
            .parse()
            .map_err(|_| ControllerIdentityError::InvalidAttempt)?;
        Self::new(run, attempt).ok_or(ControllerIdentityError::Empty)
    }
    pub fn run(self) -> u64 {
        self.run.get()
    }
    pub fn attempt(self) -> u32 {
        self.attempt.get()
    }
}

#[cfg(test)]
mod identity_tests {
    use super::{ControllerIdentity, ControllerIdentityError};

    #[test]
    fn accepts_and_preserves_positive_identity_boundaries() -> Result<(), &'static str> {
        for (run, attempt) in [(1, 1), (u64::MAX, u32::MAX)] {
            let identity = ControllerIdentity::new(run, attempt).ok_or("nonzero identity")?;
            assert_eq!((identity.run(), identity.attempt()), (run, attempt));
        }
        assert!(ControllerIdentity::new(0, 1).is_none());
        assert!(ControllerIdentity::new(1, 0).is_none());
        Ok(())
    }

    #[test]
    fn refuses_malformed_overflowing_and_zero_fields_with_causal_errors() {
        assert!(ControllerIdentity::parse("1", "1").is_ok());
        for (run, attempt, error) in [
            ("x", "1", ControllerIdentityError::InvalidRun),
            ("1", "x", ControllerIdentityError::InvalidAttempt),
            (
                "18446744073709551616",
                "1",
                ControllerIdentityError::InvalidRun,
            ),
            ("1", "4294967296", ControllerIdentityError::InvalidAttempt),
            ("0", "1", ControllerIdentityError::Empty),
            ("1", "0", ControllerIdentityError::Empty),
        ] {
            assert_eq!(ControllerIdentity::parse(run, attempt), Err(error));
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(kani, derive(kani::Arbitrary))]
pub enum PublicationPhase {
    Draft,
    Hex,
    Npm,
    Finalize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DraftEvidenceSource {
    ReleaseApi,
    CompletedPreparation,
}

impl PublicationPhase {
    pub const ALL: [Self; 4] = [Self::Draft, Self::Hex, Self::Npm, Self::Finalize];

    pub fn parse(value: &str) -> Result<Self, &'static str> {
        match value {
            "draft" => Ok(Self::Draft),
            "hex" => Ok(Self::Hex),
            "npm" => Ok(Self::Npm),
            "finalize" => Ok(Self::Finalize),
            _ => Err("unknown publication phase"),
        }
    }

    pub fn job(self) -> &'static str {
        match self {
            Self::Draft => "draft",
            Self::Hex => "hex",
            Self::Npm => "npm",
            Self::Finalize => "finalize",
        }
    }

    pub fn environment(self) -> &'static str {
        match self {
            Self::Draft => "release-github",
            Self::Hex => "release-hex",
            Self::Npm => "release-npm",
            Self::Finalize => "release",
        }
    }

    pub fn draft_evidence(self) -> DraftEvidenceSource {
        match self {
            Self::Draft | Self::Finalize => DraftEvidenceSource::ReleaseApi,
            Self::Hex | Self::Npm => DraftEvidenceSource::CompletedPreparation,
        }
    }
}

pub fn with_draft_evidence<T>(
    phase: PublicationPhase,
    release: impl FnOnce() -> T,
    preparation: impl FnOnce() -> T,
) -> T {
    match phase.draft_evidence() {
        DraftEvidenceSource::ReleaseApi => release(),
        DraftEvidenceSource::CompletedPreparation => preparation(),
    }
}

pub fn acquire_release<T, E>(
    discover: impl FnOnce() -> Result<Option<T>, E>,
    create: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    match discover()? {
        Some(release) => Ok(release),
        None => create(),
    }
}

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
pub struct ReleaseId(u64);

impl ReleaseId {
    pub fn new(value: u64) -> Option<Self> {
        if value == 0 { None } else { Some(Self(value)) }
    }

    pub fn get(self) -> u64 {
        self.0
    }

    pub fn parse(text: &str) -> Option<Self> {
        Self::new(text.parse().ok()?)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReleaseSelection {
    Missing,
    Unique(ReleaseId),
    Ambiguous,
}

impl ReleaseSelection {
    pub fn include(self, id: ReleaseId) -> Self {
        match self {
            Self::Missing => Self::Unique(id),
            Self::Unique(_) | Self::Ambiguous => Self::Ambiguous,
        }
    }
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
    fn release_acquisition_preserves_identity_without_repeated_discovery() {
        let existing: Option<u64> = kani::any();
        let created: u64 = kani::any();
        let discovery_fails: bool = kani::any();
        let creation_fails: bool = kani::any();
        let mut discoveries = 0_u8;
        let mut creations = 0_u8;
        let result = super::acquire_release(
            || {
                discoveries += 1;
                if discovery_fails {
                    Err(false)
                } else {
                    Ok(existing)
                }
            },
            || {
                creations += 1;
                if creation_fails {
                    Err(true)
                } else {
                    Ok(created)
                }
            },
        );
        assert!(discoveries == 1);
        match (discovery_fails, existing) {
            (true, _) => {
                assert!(result == Err(false));
                assert!(creations == 0);
            }
            (false, Some(id)) => {
                assert!(result == Ok(id));
                assert!(creations == 0);
            }
            (false, None) => {
                assert!(creations == 1);
                assert!(
                    result
                        == if creation_fails {
                            Err(true)
                        } else {
                            Ok(created)
                        }
                );
            }
        }
        kani::cover!(result == Ok(created) && creations == 1);
        kani::cover!(creations == 0);
        kani::cover!(result == Err(true));
        kani::cover!(result == Err(false));
    }

    #[kani::proof]
    fn registry_phases_need_no_github_release_authority() {
        let phase: super::PublicationPhase = kani::any();
        let mut release_calls = 0_u8;
        let mut preparation_calls = 0_u8;
        let source = super::with_draft_evidence(
            phase,
            || {
                release_calls += 1;
                super::DraftEvidenceSource::ReleaseApi
            },
            || {
                preparation_calls += 1;
                super::DraftEvidenceSource::CompletedPreparation
            },
        );
        match phase {
            super::PublicationPhase::Hex | super::PublicationPhase::Npm => {
                assert!(source == super::DraftEvidenceSource::CompletedPreparation);
                assert!(release_calls == 0 && preparation_calls == 1);
            }
            super::PublicationPhase::Draft | super::PublicationPhase::Finalize => {
                assert!(source == super::DraftEvidenceSource::ReleaseApi);
                assert!(release_calls == 1 && preparation_calls == 0);
            }
        }
        kani::cover!(release_calls == 1);
        kani::cover!(preparation_calls == 1);
    }

    #[kani::proof]
    fn release_selection_requires_one_valid_identity() {
        let run: u64 = kani::any();
        let attempt: u32 = kani::any();
        let controller = super::ControllerIdentity::new(run, attempt);
        assert!(controller.is_some() == (run != 0 && attempt != 0));
        if let Some(identity) = controller {
            assert!(identity.run() == run && identity.attempt() == attempt);
        }
        kani::cover!(controller.is_some());
        kani::cover!(controller.is_none());
        let raw: u64 = kani::any();
        let id = super::ReleaseId::new(raw);
        assert!(id.is_some() == (raw != 0));
        if let Some(id) = id {
            assert!(id.0 == raw && id.get() == raw);
            let previous: u64 = kani::any();
            let state = if kani::any() {
                super::ReleaseSelection::Ambiguous
            } else {
                match super::ReleaseId::new(previous) {
                    None => super::ReleaseSelection::Missing,
                    Some(id) => super::ReleaseSelection::Unique(id),
                }
            };
            let result = state.include(id);
            match state {
                super::ReleaseSelection::Missing => {
                    assert!(result == super::ReleaseSelection::Unique(id));
                }
                super::ReleaseSelection::Unique(_) | super::ReleaseSelection::Ambiguous => {
                    assert!(result == super::ReleaseSelection::Ambiguous);
                }
            }
            kani::cover!(state == super::ReleaseSelection::Missing);
            kani::cover!(matches!(state, super::ReleaseSelection::Unique(_)));
            kani::cover!(state == super::ReleaseSelection::Ambiguous);
        }
    }

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
