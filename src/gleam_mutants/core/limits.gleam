// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

pub const minimum_jobs = 1

pub const maximum_jobs = 32

pub const minimum_timeout_ms = 100

pub const maximum_timeout_ms = 86_400_000

pub const interrupt_exit_code = 130

pub const terminate_exit_code = 143

pub const unshared_file_link_count = 1

pub const compiler_rejection_exit_code = 1

pub fn valid_jobs(value: Int) -> Bool {
  value >= minimum_jobs && value <= maximum_jobs
}

pub fn valid_timeout(value: Int) -> Bool {
  value >= minimum_timeout_ms && value <= maximum_timeout_ms
}

pub fn interrupted(value: Int) -> Bool {
  value == interrupt_exit_code || value == terminate_exit_code
}

pub fn unshared_file(value: Int) -> Bool {
  value == unshared_file_link_count
}

pub fn compiler_rejected(value: Int) -> Bool {
  value == compiler_rejection_exit_code
}
