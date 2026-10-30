// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#[path = "../../fuzz/checks/core_source.rs"]
mod properties;

#[test]
fn preserved_core_sources_replay_the_parser_round_trips() {
    let directory =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../fuzz/corpus/core_source");
    let mut seeds: Vec<_> = std::fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    seeds.sort();
    assert!(!seeds.is_empty());
    let mut admitted = std::collections::BTreeSet::new();
    for seed in seeds {
        admitted.extend(properties::check(&std::fs::read(seed).unwrap()));
    }
    assert_eq!(
        admitted,
        properties::CoreSource::ALL.iter().copied().collect()
    );
    assert!(properties::check(&[]).is_empty());
    assert!(properties::check(&[u8::MAX]).is_empty());
}
