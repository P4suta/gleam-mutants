// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use gleam_mutants_verification::{fragment, outcome, paths, scoring, selection, span};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum CoreSource {
    Span,
    Outcome,
    Score,
    Policy,
    Operator,
    Plan,
    Path,
    Glob,
    Types,
}

impl CoreSource {
    #[cfg(test)]
    pub const ALL: &'static [Self] = &[
        Self::Span,
        Self::Outcome,
        Self::Score,
        Self::Policy,
        Self::Operator,
        Self::Plan,
        Self::Path,
        Self::Glob,
        Self::Types,
    ];
}

pub fn check(data: &[u8]) -> BTreeSet<CoreSource> {
    let mut admitted = BTreeSet::new();
    let Ok(source) = std::str::from_utf8(data) else {
        return admitted;
    };
    if let Ok(model) = span::derive(source) {
        let canonical = span::canonical_source(source).expect("admitted span source");
        assert_eq!(span::derive(&canonical).unwrap(), model);
        assert_eq!(span::canonical_source(&canonical).unwrap(), canonical);
        admitted.insert(CoreSource::Span);
    }
    type Derive = fn(&str) -> Result<String, String>;
    for (kind, derive) in [
        (CoreSource::Outcome, outcome::derive as Derive),
        (CoreSource::Score, scoring::derive_score),
        (CoreSource::Policy, scoring::derive_policy),
        (CoreSource::Operator, selection::derive_operator),
        (CoreSource::Plan, selection::derive_plan),
        (CoreSource::Path, paths::derive_path),
        (CoreSource::Glob, paths::derive_glob),
    ] {
        if let Ok(model) = derive(source) {
            let canonical = fragment::tokens(source).unwrap().join(" ");
            assert_eq!(derive(&canonical).unwrap(), model);
            assert_eq!(fragment::tokens(&canonical).unwrap().join(" "), canonical);
            admitted.insert(kind);
        }
    }
    for name in ["Outcome", "Runtime", "RuntimeOutcome", "Score", "Operator"] {
        if let Ok(declaration) = fragment::declaration(source, name) {
            assert_eq!(
                fragment::declaration(&declaration, name).unwrap(),
                declaration
            );
        }
    }
    if fragment::validate_types(source).is_ok() {
        fragment::validate_types(&fragment::tokens(source).unwrap().join(" ")).unwrap();
        admitted.insert(CoreSource::Types);
    }
    admitted
}
