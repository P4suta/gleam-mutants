// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam_mutants/core/path

pub fn parent_preserves_absolute_roots_test() {
  assert path.parent("") == ""
  assert path.parent("/child") == "/"
  assert path.parent("/") == "/"
  assert path.parent("C:/child") == "C:/"
  assert path.parent("C:/") == "C:/"
  assert path.parent("//server/share/child") == "//server/share/"
  assert path.parent("//server/share/") == "//server/share/"
  assert path.parent("/child/") == "/"
  assert path.parent("C:/child/") == "C:/"
  assert path.parent("//server/share/child/") == "//server/share/"
  assert path.parent("src/child.gleam") == "src"
  assert path.parent("child.gleam") == ""
  assert path.parent("src/child.gleam/") == "src"
}

@target(javascript)
pub fn absolute_parents_match_an_independent_node_reference_test() {
  let values = components(4)
  list.each(
    [#("/", False), #("C:/", True), #("//server/share/", True)],
    fn(root) {
      list.each(values, fn(value) {
        let source = reference(root.0 <> value, root.1)
        let expected = reference(reference_parent(source, root.1), root.1)
        assert path.parent(source) == expected
      })
    },
  )
}

@target(javascript)
fn reference_parent(value: String, windows: Bool) -> String {
  case windows {
    True -> reference_windows_parent(value)
    False -> reference_posix_parent(value)
  }
}

@target(javascript)
@external(javascript, "node:path/posix", "dirname")
fn reference_posix_parent(value: String) -> String

@target(javascript)
@external(javascript, "node:path/win32", "dirname")
fn reference_windows_parent(value: String) -> String

@target(javascript)
import gleam/list

@target(javascript)
pub fn absolute_paths_match_an_independent_node_reference_test() {
  let values = components(5)
  assert list.length(values) == 3906
  list.each(
    [#("/root/", False), #("C:/root/", True), #("//server/share/root/", True)],
    fn(root) {
      list.each(values, fn(value) {
        let source = root.0 <> value
        let actual = path.normalize_absolute(source, root.1)
        assert actual == reference(source, root.1)
        assert path.normalize_absolute(actual, root.1) == actual
      })
    },
  )
}

@target(javascript)
fn components(depth: Int) -> List(String) {
  case depth {
    0 -> [""]
    _ -> [
      "",
      ..list.flat_map(["node", ".", "..", " name ", "日本語"], fn(segment) {
        list.map(components(depth - 1), fn(rest) {
          case rest {
            "" -> segment
            _ -> segment <> "/" <> rest
          }
        })
      })
    ]
  }
}

pub fn absolute_roots_and_native_spelling_are_preserved_test() {
  assert path.normalize_absolute("/../../", False) == "/"
  assert path.normalize_absolute("C:/../../", True) == "C:/"
  assert path.normalize_absolute("//server/share/../../", True)
    == "//server/share/"
  assert path.normalize_absolute("/root/native\\name/./ child ", False)
    == "/root/native\\name/ child "
  assert path.normalize_absolute("C:\\root\\.\\child\\..", True) == "C:/root"
}

@target(javascript)
fn reference(value: String, windows: Bool) -> String {
  case windows {
    True -> path.from_native(reference_windows(value), True)
    False -> reference_posix(value)
  }
}

@target(javascript)
@external(javascript, "node:path/posix", "resolve")
fn reference_posix(value: String) -> String

@target(javascript)
@external(javascript, "node:path/win32", "resolve")
fn reference_windows(value: String) -> String
