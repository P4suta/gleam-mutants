// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

pub const minimum_jobs = 1

pub const maximum_jobs = 32

pub const minimum_timeout_ms = 100

pub const maximum_timeout_ms = 86_400_000

pub const interrupt_exit_code = 130

pub const terminate_exit_code = 143

pub fn valid_jobs(value: Int) -> Bool {
  value >= minimum_jobs && value <= maximum_jobs
}

pub fn valid_timeout(value: Int) -> Bool {
  value >= minimum_timeout_ms && value <= maximum_timeout_ms
}

pub fn interrupted(value: Int) -> Bool {
  value == interrupt_exit_code || value == terminate_exit_code
}
