// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/io
import gleam/list
import gleam/string
import gleam_mutants/core/path
import gleam_mutants/platform
import gleam_mutants/test_impact
import simplifile

pub fn main() {
  let runtimes = case platform.arguments() {
    [] -> ["erlang", "node"]
    selected -> selected
  }
  list.each(runtimes, verify_runtime)
  list.each(runtimes, verify_symlinked_workspace)
}

/// The protocol survives a working directory reached through a symbolic link.
///
/// macOS answers `getcwd` with the `/private/var` that a `/var` path resolves
/// to, so a snapshot under the temporary directory has two spellings: the one
/// the engine built its paths from and the one the test process is told it is
/// in. A runner that compares those as strings refuses its own protocol file,
/// which turns adaptive selection off and fails a test nobody wrote. Naming
/// the file relative to the directory the process is already in is what stops
/// that, because a name cannot disagree with itself.
///
/// `ln` is POSIX, and Windows makes a copy of the directory rather than a link
/// to it unless the account may create one. Nothing is being asserted about a
/// copy -- it is reached by the name it has, so there is no second spelling to
/// disagree over -- so a platform that made one is answered with a skip rather
/// than a failure over something no change of ours can fix.
fn verify_symlinked_workspace(runtime: String) -> Nil {
  let root = platform.current_directory()
  let link =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-protocol-link-" <> platform.random_nonce(),
    )
  let linked = platform.run_process("ln", ["-s", root, link], root, [], 10_000)
  let is_link = case simplifile.link_info(link) {
    Ok(info) -> simplifile.file_info_type(info) == simplifile.Symlink
    Error(_) -> False
  }
  case linked.status == 0 && is_link {
    False -> {
      // `rm` without `-r` removes a link and refuses a directory, so a copy
      // is left where it cannot be mistaken for the workspace it copied.
      let _ = platform.run_process("rm", [link], root, [], 10_000)
      io.println("skipped: this platform made no symbolic link to a workspace")
    }
    True -> {
      let name =
        "smartest-protocol-link-"
        <> runtime
        <> "-"
        <> platform.random_nonce()
        <> ".json"
      // The engine names its protocol files under a snapshot root it took
      // from `TMPDIR`, and the link is that spelling here: the one `getcwd`
      // will not answer with.
      let through_link = path.join(path.join(link, ".gleam_mutants"), name)
      let refused =
        run_in(link, runtime, [
          #("GLEAM_MUTANTS_ACTIVE", ""),
          #("GLEAM_MUTANTS_RUNTIME", runtime),
          #("GLEAM_MUTANTS_TEST_IMPACT_FILE", through_link),
          #("SMARTEST_FILTER", "smartest_native_fixture"),
        ])
      let accepted =
        run_in(link, runtime, [
          #("GLEAM_MUTANTS_ACTIVE", ""),
          #("GLEAM_MUTANTS_RUNTIME", runtime),
          #(
            "GLEAM_MUTANTS_TEST_IMPACT_FILE",
            test_impact.protocol_name(through_link),
          ),
          #("SMARTEST_FILTER", "smartest_native_fixture"),
        ])
      // `rm` without `-r` unlinks the link and can never reach the workspace
      // it points at, which `delete_tree` gives no such promise about.
      let _ = platform.run_process("rm", [link], root, [], 10_000)

      // The absolute name is refused, which is the whole reason the relative
      // one is what the engine hands over.
      assert refused.status != 0
      assert string.contains(
        refused.stdout <> refused.stderr,
        "impact file must be below .gleam_mutants",
      )

      assert accepted.status == 0
      let written = path.join(path.join(root, ".gleam_mutants"), name)
      let assert Ok(source) = simplifile.read(written)
      let assert Ok(manifest) = test_impact.decode_manifest(source)
      assert manifest.runtime == runtime
      assert manifest.complete
      let assert Ok(Nil) = simplifile.delete_file(at: written)
      Nil
    }
  }
}

fn verify_runtime(runtime: String) -> Nil {
  let root = platform.current_directory()
  let private = path.join(root, ".gleam_mutants")
  let impact =
    path.join(
      private,
      "smartest-protocol-"
        <> runtime
        <> "-"
        <> platform.random_nonce()
        <> ".json",
    )
  let baseline =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #("GLEAM_MUTANTS_TEST_IMPACT_FILE", test_impact.protocol_name(impact)),
      #("SMARTEST_FILTER", "smartest_native_fixture"),
    ])
  assert baseline.status == 0
  let assert Ok(source) = simplifile.read(impact)
  let assert Ok(manifest) = test_impact.decode_manifest(source)
  assert manifest.runner == "smartest"
  assert manifest.runtime == runtime
  assert manifest.complete
  assert list.map(manifest.tests, fn(descriptor) { descriptor.kind })
    == ["smartest-leaf", "smartest-leaf"]
  let assert [first, _] = manifest.tests

  let assert Ok(selection) =
    test_impact.write_selection(root, runtime, "smartest", [first.selector])
  let narrowed =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #(
        "GLEAM_MUTANTS_TEST_SELECTION_FILE",
        test_impact.protocol_name(selection),
      ),
      #("SMARTEST_FILTER", "smartest_native_fixture"),
    ])
  assert narrowed.status == 0
  assert string.contains(narrowed.stdout, "1 passed, 0 failed")

  let legacy_impact =
    path.join(
      private,
      "smartest-protocol-legacy-"
        <> runtime
        <> "-"
        <> platform.random_nonce()
        <> ".json",
    )
  let legacy_baseline =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #(
        "GLEAM_MUTANTS_TEST_IMPACT_FILE",
        test_impact.protocol_name(legacy_impact),
      ),
      #("SMARTEST_FILTER", "stable_id_is_path_separator_portable"),
    ])
  assert legacy_baseline.status == 0
  let assert Ok(legacy_source) = simplifile.read(legacy_impact)
  let assert Ok(legacy_manifest) = test_impact.decode_manifest(legacy_source)
  let assert [legacy_descriptor] = legacy_manifest.tests
  assert legacy_descriptor.kind == "legacy-export"
  let assert Ok(legacy_selection) =
    test_impact.write_selection(root, runtime, "smartest", [
      legacy_descriptor.selector,
    ])
  let legacy_narrowed =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #(
        "GLEAM_MUTANTS_TEST_SELECTION_FILE",
        test_impact.protocol_name(legacy_selection),
      ),
      #("SMARTEST_FILTER", "stable_id_is_path_separator_portable"),
    ])
  assert legacy_narrowed.status == 0
  assert string.contains(legacy_narrowed.stdout, "1 passed, 0 failed")

  let assert Ok(unknown) =
    test_impact.write_selection(root, runtime, "smartest", ["unknown/test"])
  let rejected =
    run(runtime, [
      #("GLEAM_MUTANTS_ACTIVE", ""),
      #("GLEAM_MUTANTS_RUNTIME", runtime),
      #("GLEAM_MUTANTS_TEST_SELECTION_FILE", test_impact.protocol_name(unknown)),
      #("SMARTEST_FILTER", "smartest_native_fixture"),
    ])
  assert rejected.status != 0
  assert string.contains(
    rejected.stdout <> rejected.stderr,
    "unknown test selector",
  )

  let assert Ok(Nil) = simplifile.delete_file(at: impact)
  let assert Ok(Nil) = simplifile.delete_file(at: selection)
  let assert Ok(Nil) = simplifile.delete_file(at: legacy_impact)
  let assert Ok(Nil) = simplifile.delete_file(at: legacy_selection)
  let assert Ok(Nil) = simplifile.delete_file(at: unknown)
  let assert Ok(entries) = simplifile.read_directory(private)
  assert !list.any(entries, fn(entry) {
    string.contains(entry, "smartest-protocol-")
    && string.contains(entry, ".tmp-")
  })
}

fn run(runtime: String, environment: List(#(String, String))) {
  run_in(platform.current_directory(), runtime, environment)
}

fn run_in(
  directory: String,
  runtime: String,
  environment: List(#(String, String)),
) {
  let arguments = case runtime {
    "erlang" -> ["test", "--target", "erlang"]
    javascript -> [
      "test",
      "--target",
      "javascript",
      "--runtime",
      javascript,
    ]
  }
  platform.run_process("gleam", arguments, directory, environment, 30_000)
}
