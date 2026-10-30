// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::fragment::{bind, boolean, choice, natural, scalar_literal};

pub fn derive_path(source: &str) -> Result<String, String> {
    let values = bind(source, include_str!("../fragments/path.gleam.in"))?;
    let parent_prefix = match choice(&values, "__parent_prefix", &["root", "\"\""])? {
        "root" => "root",
        "\"\"" => "[]",
        _ => unreachable!("choice checks the parent prefix domain"),
    };
    Ok(format!(
        r#"namespace PathDerived
def from_native (value : List Nat) (windows : Bool) : List Nat :=
  if windows then value.map (fun c => if c = 92 then 47 else c) else value
def splitSlash : List Nat → List (List Nat)
  | [] => [[]]
  | c :: rest =>
    let parts := splitSlash rest
    if c = 47 then [] :: parts else match parts with
      | [] => [[c]]
      | head :: tail => (c :: head) :: tail
def joinSlash (parts : List (List Nat)) : List Nat := List.intercalate [47] parts
def rootParts (parts : List (List Nat)) (windows : Bool) : List Nat × List (List Nat) :=
  match parts, windows with
  | [] :: [] :: server :: share :: rest, true => ({unc_prefix} ++ server ++ {unc_separator} ++ share ++ {unc_suffix}, rest)
  | [] :: rest, _ => ({posix_root}, rest)
  | drive :: rest, true => (drive ++ {drive_root}, rest)
  | parts, _ => ({relative_root}, parts)
def step (reversed : List (List Nat)) (segment : List Nat) : List (List Nat) :=
  if segment = [] ∨ segment = [46] then reversed
  else if segment = [46, 46] then reversed.drop {drop} else segment :: reversed
def normalizeSegments (segments : List (List Nat)) : List (List Nat) := (segments.foldl step []).reverse
def normalize_absolute (value : List Nat) (windows : Bool) : List Nat :=
  let (root, segments) := rootParts (splitSlash (from_native value windows)) windows
  root ++ joinSlash (normalizeSegments segments)
def join (left right : List Nat) : List Nat :=
  if left = [] then right else if right = [] then left else left ++ {join_separator} ++ right
def driveRoot (value : List Nat) : Bool := match value with
  | [letter, 58] => ({alphabet} : List Nat).contains letter
  | _ => false
def parentWindows (parts : List (List Nat)) : Bool := match parts with
  | [] :: [] :: server :: share :: _ => decide (server ≠ []) && decide (share ≠ [])
  | drive :: _ :: _ => driveRoot drive
  | _ => false
def parentSegments (segments : List (List Nat)) : List (List Nat) :=
  ((segments.reverse.dropWhile (fun segment => decide (segment = []))).drop {parent_drop}).reverse
def parentParts (parts : List (List Nat)) : List Nat :=
  let (root, segments) := rootParts parts (parentWindows parts)
  {parent_prefix} ++ joinSlash (parentSegments segments)
def parent (value : List Nat) : List Nat := if value = [] then [] else parentParts (splitSlash value)
def base_name (value : List Nat) : List Nat := (splitSlash value).getLast?.getD []
end PathDerived
"#,
        unc_prefix = scalar_literal(&values, "__unc_prefix")?,
        unc_separator = scalar_literal(&values, "__unc_separator")?,
        unc_suffix = scalar_literal(&values, "__unc_suffix")?,
        posix_root = scalar_literal(&values, "__posix_root")?,
        drive_root = scalar_literal(&values, "__drive_root")?,
        relative_root = scalar_literal(&values, "__relative_root")?,
        drop = natural(&values, "__drop")?,
        join_separator = scalar_literal(&values, "__join_separator")?,
        parent_drop = natural(&values, "__parent_drop")?,
        alphabet = scalar_literal(&values, "__alphabet")?,
    ))
}

pub fn derive_glob(source: &str) -> Result<String, String> {
    let values = bind(source, include_str!("../fragments/glob.gleam.in"))?;
    let relation = |name| {
        choice(&values, name, &["!=", "=="]).map(|value| if value == "!=" { "≠" } else { "=" })
    };
    Ok(format!(
        r#"namespace GlobDerived
inductive Glyph where
  | star | question | slash
  | other (value : List Nat)
  deriving DecidableEq
mutual
def accepts : List Glyph → List Glyph → Bool
  | [], [] => {empty}
  | [], _ => {missing_pattern}
  | .star :: .star :: .slash :: rest, path => accepts rest path || afterDirectory rest path
  | .star :: .star :: rest, path => accepts rest path || match path with
    | [] => {globstar_empty}
    | _ :: pathRest => accepts (.star :: .star :: rest) pathRest
  | .star :: rest, path => accepts rest path || match path with
    | segment :: pathRest => if segment {star_guard} Glyph.slash then accepts (.star :: rest) pathRest else {star_failure}
    | [] => {star_failure}
  | .question :: rest, segment :: pathRest => if segment {question_guard} Glyph.slash then accepts rest pathRest else if Glyph.question = segment then accepts rest pathRest else {unmatched}
  | expected :: patternRest, actual :: pathRest => if expected = actual then accepts patternRest pathRest else {unmatched}
  | _, _ => {unmatched}
termination_by pattern path => pattern.length + path.length
decreasing_by all_goals simp_all <;> omega
def afterDirectory : List Glyph → List Glyph → Bool
  | _, [] => {directory_empty}
  | pattern, segment :: pathRest => if segment {directory_guard} Glyph.slash then
      accepts pattern pathRest || afterDirectory pattern pathRest
    else afterDirectory pattern pathRest
termination_by pattern path => pattern.length + path.length
decreasing_by all_goals simp_all <;> omega
end
def included (path : List Glyph) (includes excludes : List (List Glyph)) : Bool :=
  includes.any (fun pattern => accepts pattern path) {connective} !excludes.any (fun pattern => accepts pattern path)
end GlobDerived
"#,
        empty = boolean(&values, "__empty")?,
        missing_pattern = boolean(&values, "__missing_pattern")?,
        directory_empty = boolean(&values, "__directory_empty")?,
        globstar_empty = boolean(&values, "__globstar_empty")?,
        star_guard = relation("__star_guard")?,
        star_failure = boolean(&values, "__star_failure")?,
        question_guard = relation("__question_guard")?,
        directory_guard = relation("__directory_guard")?,
        unmatched = boolean(&values, "__unmatched")?,
        connective = choice(&values, "__connective", &["&&", "||"])?
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    const PATH: &str = include_str!("../../src/gleam_mutants/core/path.gleam");
    const GLOB: &str = include_str!("../../src/gleam_mutants/core/glob.gleam");

    #[test]
    fn derives_path_reduction_and_wildcard_guards() {
        let original = derive_path(PATH).unwrap();
        assert_ne!(
            derive_path(&PATH.replace("list.drop(reversed, 1)", "list.drop(reversed, 2)")).unwrap(),
            original
        );
        let original = derive_glob(GLOB).unwrap();
        assert_ne!(
            derive_glob(&GLOB.replace("[], [] -> True", "[], [] -> False")).unwrap(),
            original
        );
        assert_ne!(
            derive_glob(&GLOB.replace("segment != \"/\"", "segment == \"/\"")).unwrap(),
            original
        );
        assert_ne!(
            derive_glob(&GLOB.replace("case segment == \"/\"", "case segment != \"/\"")).unwrap(),
            original
        );
        assert!(derive_glob(&GLOB.replace("list.any", "list.all")).is_err());
    }
}
