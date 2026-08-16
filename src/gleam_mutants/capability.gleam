// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/platform.{type ProcessResult}
import simplifile.{type FileError}

pub type FileSystem {
  FileSystem(
    read: fn(String) -> Result(String, FileError),
    write: fn(String, String) -> Result(Nil, FileError),
    list: fn(String) -> Result(List(String), FileError),
  )
}

pub type ProcessRunner {
  ProcessRunner(
    run: fn(String, List(String), String, List(#(String, String)), Int) ->
      ProcessResult,
  )
}

pub type Clock {
  Clock(now_milliseconds: fn() -> Int)
}

pub type Capabilities {
  Capabilities(filesystem: FileSystem, process: ProcessRunner, clock: Clock)
}

pub fn concrete() -> Capabilities {
  Capabilities(
    filesystem: FileSystem(
      simplifile.read,
      simplifile.write,
      simplifile.read_directory,
    ),
    process: ProcessRunner(platform.run_process),
    clock: Clock(platform.now_milliseconds),
  )
}
