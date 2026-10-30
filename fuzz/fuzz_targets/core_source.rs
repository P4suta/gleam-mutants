// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

#![no_main]

#[path = "../checks/core_source.rs"]
mod properties;

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    drop(properties::check(data));
});
