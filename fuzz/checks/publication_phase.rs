// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use gleam_mutants_release::candidate::Revision;
use gleam_mutants_release::publication::{ControllerIdentity, Phase};
use gleam_mutants_release_core::{ReleaseId, acquire_release};

pub fn check(data: &[u8]) {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let phase = Phase::parse(text);
    assert_eq!(
        phase.is_ok(),
        ["draft", "hex", "npm", "finalize"].contains(&text)
    );
    if let Ok(phase) = phase {
        assert_eq!(phase.job(), text);
        assert_eq!(Phase::parse(phase.job()), Ok(phase));
        assert!(!phase.environment().is_empty());
    }
    let (run, attempt) = text.split_once('|').unwrap_or((text, text));
    let identity = ControllerIdentity::parse(run, attempt);
    let numbers = run.parse::<u64>().ok().zip(attempt.parse::<u32>().ok());
    assert_eq!(
        identity.is_ok(),
        numbers.is_some_and(|(run, attempt)| run != 0 && attempt != 0)
    );
    if let Ok(identity) = identity {
        assert!(identity.run() != 0 && identity.attempt() != 0);
        assert_eq!(
            ControllerIdentity::parse(&identity.run().to_string(), &identity.attempt().to_string()),
            Ok(identity)
        );
    }
    let existing = ReleaseId::parse(run);
    let created = ReleaseId::parse(attempt);
    if let Some(id) = existing {
        assert_eq!(ReleaseId::parse(&id.get().to_string()), Some(id));
        assert!(id.get() > 0);
    }
    let mut creations = 0;
    let observed = acquire_release(
        || Ok(existing),
        || {
            creations += 1;
            created.ok_or(())
        },
    );
    assert_eq!(creations, usize::from(existing.is_none()));
    assert_eq!(observed, existing.or(created).ok_or(()));
    const REVISION_BYTES: usize = 40;
    let revision = Revision::try_from(text.to_owned());
    assert_eq!(
        revision.is_ok(),
        text.len() == REVISION_BYTES
            && text
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    );
    if let Ok(revision) = revision {
        assert_eq!(revision.as_str(), text);
        assert_eq!(
            Revision::try_from(String::from(revision.clone())),
            Ok(revision)
        );
    }
}
