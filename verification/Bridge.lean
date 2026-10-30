/-
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-/

import Derived

private def emit (fields : List String) : IO Unit :=
  IO.println ("bridge:" ++ String.intercalate ":" fields)

private def bit (value : Bool) : String := if value then "1" else "0"

private def scalars (value : String) : List Nat := value.toList.map Char.toNat
private def textCode (value : List Nat) : String := String.intercalate "." (value.map toString)
private def text (value : List Nat) : String := String.ofList (value.map Char.ofNat)

private def outcomeText : OutcomeDerived.Outcome → String
  | .killed => "killed"
  | .survived => "survived"
  | .timedOut => "timedOut"
  | .testError message => "error:" ++ String.ofList (message.map Char.ofNat)

private def spanChecks : IO Unit := do
  let numbers : List Int := [-1, 0, 1, 2, 3, 4, 9007199254740990, 9007199254740991]
  for start in numbers do
    for finish in numbers do
      let result := match SpanDerived.new start finish with
        | .error .negativeStart => "negativeStart"
        | .error .endBeforeStart => "endBeforeStart"
        | .ok value => "ok:" ++ toString (SpanDerived.start value) ++ ":" ++
          toString (SpanDerived.end value) ++ ":" ++ toString (SpanDerived.length value)
      emit ["constructor", toString start, toString finish, result]
  let spans := numbers.flatMap fun start => numbers.filterMap fun finish =>
    match SpanDerived.new start finish with
    | .ok value => some value
    | .error _ => none
  for a in spans do
    for b in spans do
      let ordering := match SpanDerived.compare a b with
        | .lt => "lt"
        | .eq => "eq"
        | .gt => "gt"
      emit ["span", toString a.start, toString a.end, toString b.start, toString b.end,
        bit (SpanDerived.equal a b), bit (SpanDerived.contains a b),
        bit (SpanDerived.strictly_contains a b), bit (SpanDerived.overlaps a b),
        bit (SpanDerived.partially_overlaps a b), ordering]

private def sequences : Nat → List (List OutcomeDerived.Outcome)
  | 0 => [[]]
  | n + 1 =>
    let values := [OutcomeDerived.Outcome.killed, .survived, .timedOut,
      .testError [65], .testError ("理由".toList.map Char.toNat)]
    values.flatMap fun head => (sequences n).map fun rest => head :: rest

private def outcomeChecks : IO Unit := do
  for size in [0, 1, 2, 3, 4] do
    for values in sequences size do
      let score := ScoreDerived.calculate values
      emit ["outcome", String.intercalate "," (values.map outcomeText),
        outcomeText (OutcomeDerived.aggregate values), toString score.total,
        toString score.killed, toString score.timed_out, toString score.survived,
        toString score.errors, "1", "1"]

private def policyChecks : IO Unit := do
  for errors in ([-1, 0, 1] : List Int) do
    for override in [none, some false, some true] do
      for below in [false, true] do
        let strictText := match override with | none => "none" | some value => bit value
        emit ["policy", toString errors, strictText, bit below,
          toString (PolicyDerived.code errors override below)]

private def identityChecks : IO Unit := do
  for value in OperatorDerived.all do
    let name := OperatorDerived.name value
    emit ["operator", text name, toString (OperatorDerived.version value),
      bit (decide (OperatorDerived.from_name name = some value))]
  for value in [OutcomeDerived.Runtime.erlang, .node, .deno, .bun] do
    emit ["runtime", text (OutcomeDerived.runtime_name value)]
  for value in [OutcomeDerived.Outcome.killed, .survived, .timedOut,
      .testError [65], .testError (scalars "理由")] do
    emit ["detection", outcomeText value, bit (OutcomeDerived.detected value),
      bit (OutcomeDerived.is_detected value)]

private def pathChecks : IO Unit := do
  for input in ["", "/", "/child", "/child/", "C:/", "C:/child", "C:/child/",
      "//server/share/", "//server/share/child", "/a/./b/../c", "/../../", "C:\\a\\..\\b",
      "\\\\server\\share\\a\\..\\b", "/日本 語/../x", "a/./../b"] do
    let value := scalars input
    for windows in [false, true] do
      emit ["path", textCode value, bit windows, textCode (PathDerived.from_native value windows),
        textCode (PathDerived.normalize_absolute value windows), textCode (PathDerived.parent value),
        textCode (PathDerived.base_name value)]

private def glyphCode : GlobDerived.Glyph → List Nat
  | .star => [42]
  | .question => [63]
  | .slash => [47]
  | .other value => value

private def glyphSequences : Nat → List (List GlobDerived.Glyph)
  | 0 => [[]]
  | n + 1 =>
    let values := [GlobDerived.Glyph.star, .question, .slash, .other [97], .other [101, 769]]
    values.flatMap fun head => (glyphSequences n).map fun rest => head :: rest

private def globChecks : IO Unit := do
  let paths : List (List GlobDerived.Glyph) := [[], [.other [97]], [.slash],
    [.other [97], .slash, .other [98]], [.other [101, 769]], [.other [97], .slash, .other [101, 769]],
    [.other [98], .other [101], .other [116], .other [97]]]
  for size in [0, 1, 2, 3, 4] do
    for pattern in glyphSequences size do
      for value in paths do
        emit ["glob", textCode (pattern.flatMap glyphCode), textCode (value.flatMap glyphCode),
          bit (GlobDerived.accepts pattern value), bit (GlobDerived.included value [pattern] [pattern])]

private def planChecks : IO Unit := do
  let values : List PlanDerived.Mutant := [⟨scalars "alpha", scalars "A"⟩,
    ⟨scalars "alpine", scalars "B"⟩, ⟨scalars "日本", scalars "日"⟩]
  for changed in [false, true] do
    for needle in [none, some [], some (scalars "al"), some (scalars "alpha"),
        some (scalars "B"), some (scalars "missing"), some (scalars "日")] do
      let needleText := match needle with | none => "none" | some value => "some:" ++ textCode value
      let result := match PlanDerived.build values changed needle with
        | .ok plan => text (PlanDerived.mode plan) ++ ":" ++
          String.intercalate "," ((PlanDerived.mutants plan).map fun mutant => textCode mutant.id)
        | .error (.noMatch _) => "missing"
        | .error (.ambiguous _) => "ambiguous"
      emit ["plan", bit changed, needleText, result]

def main : IO Unit := do
  spanChecks
  outcomeChecks
  policyChecks
  identityChecks
  pathChecks
  globChecks
  planChecks
