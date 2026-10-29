// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#[path = "../../../fuzz/checks/publication_phase.rs"]
mod properties;

#[test]
fn publication_phase_corpus_preserves_strict_identity_and_round_trips() {
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../fuzz/corpus/publication_phase");
    let mut seeds: Vec<_> = std::fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    seeds.sort();
    assert!(!seeds.is_empty());
    for seed in seeds {
        let bytes = std::fs::read(seed).unwrap();
        properties::check(&bytes);
        properties::check(bytes.strip_suffix(b"\n").unwrap_or(&bytes));
    }
    properties::check(&[]);
    properties::check(&[u8::MAX]);
}
