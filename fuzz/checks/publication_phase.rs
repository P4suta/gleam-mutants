// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use gleam_mutants_release::publication::Phase;

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
}
