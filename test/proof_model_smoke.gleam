// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import gleam_mutants/core/exit_policy
import gleam_mutants/core/glob
import gleam_mutants/core/operator
import gleam_mutants/core/outcome
import gleam_mutants/core/path
import gleam_mutants/core/plan
import gleam_mutants/core/score
import gleam_mutants/core/span
import gleam_mutants/types

fn number(value: Int) -> String {
  int.to_string(value)
}

fn bit(value: Bool) -> String {
  case value {
    True -> "1"
    False -> "0"
  }
}

fn emit(fields: List(String)) -> Nil {
  io.println("bridge:" <> string.join(fields, ":"))
}

fn text_code(value: String) -> String {
  value
  |> string.to_utf_codepoints
  |> list.map(fn(character) { number(string.utf_codepoint_to_int(character)) })
  |> string.join(".")
}

fn outcome_text(value: types.Outcome) -> String {
  case value {
    types.Killed -> "killed"
    types.Survived -> "survived"
    types.TimedOut -> "timedOut"
    types.TestError(message) -> "error:" <> message
  }
}

fn span_checks() -> Nil {
  let numbers = [
    -1,
    0,
    1,
    2,
    3,
    4,
    9_007_199_254_740_990,
    9_007_199_254_740_991,
  ]
  list.each(numbers, fn(start) {
    list.each(numbers, fn(end) {
      let result = case span.new(start, end) {
        Error(span.NegativeStart) -> "negativeStart"
        Error(span.EndBeforeStart) -> "endBeforeStart"
        Ok(value) ->
          "ok:"
          <> number(span.start(value))
          <> ":"
          <> number(span.end(value))
          <> ":"
          <> number(span.length(span.unsafe_new(start, end)))
      }
      emit(["constructor", number(start), number(end), result])
    })
  })
  let spans =
    list.flat_map(numbers, fn(start) {
      list.filter_map(numbers, span.new(start, _))
    })
  list.each(spans, fn(a) {
    list.each(spans, fn(b) {
      let ordering = case span.compare(a, b) {
        order.Lt -> "lt"
        order.Eq -> "eq"
        order.Gt -> "gt"
      }
      emit([
        "span",
        number(span.start(a)),
        number(span.end(a)),
        number(span.start(b)),
        number(span.end(b)),
        bit(span.equal(a, b)),
        bit(span.contains(a, b)),
        bit(span.strictly_contains(a, b)),
        bit(span.overlaps(a, b)),
        bit(span.partially_overlaps(a, b)),
        ordering,
      ])
    })
  })
}

fn sequences(length: Int) -> List(List(types.Outcome)) {
  case length {
    0 -> [[]]
    _ ->
      list.flat_map(
        [
          types.Killed,
          types.Survived,
          types.TimedOut,
          types.TestError("A"),
          types.TestError("理由"),
        ],
        fn(head) {
          list.map(sequences(length - 1), fn(rest) { [head, ..rest] })
        },
      )
  }
}

fn outcome_checks() -> Nil {
  list.each([0, 1, 2, 3, 4], fn(length) {
    list.each(sequences(length), fn(values) {
      let runtimes =
        list.index_map(values, fn(value, index) {
          types.RuntimeOutcome(
            types.Erlang,
            value,
            index,
            "metadata",
            index % 2 == 0,
          )
        })
      let calculated = score.calculate(values)
      let bounded = calculated.percent >=. 0.0 && calculated.percent <=. 100.0
      emit([
        "outcome",
        string.join(list.map(values, outcome_text), ","),
        outcome_text(outcome.aggregate(runtimes)),
        number(calculated.total),
        number(calculated.killed),
        number(calculated.timed_out),
        number(calculated.survived),
        number(calculated.errors),
        bit(bounded),
        bit(case calculated.total {
          0 -> calculated.percent == 0.0
          _ -> True
        }),
      ])
    })
  })
}

fn policy_checks() -> Nil {
  list.each([-1, 0, 1], fn(errors) {
    list.each([None, Some(False), Some(True)], fn(strict) {
      list.each([False, True], fn(below) {
        let percent = case below {
          True -> 0.0
          False -> 100.0
        }
        let context = exit_policy.Context(True, False, strict, 50.0)
        let strict_text = case strict {
          None -> "none"
          Some(value) -> bit(value)
        }
        emit([
          "policy",
          number(errors),
          strict_text,
          bit(below),
          number(exit_policy.code(
            types.Score(0, 0, 0, 0, errors, percent),
            context,
          )),
        ])
      })
    })
  })
}

fn identity_checks() -> Nil {
  list.each(operator.all(), fn(value) {
    let name = operator.name(value)
    emit([
      "operator",
      name,
      number(operator.version(value)),
      bit(operator.from_name(name) == Ok(value)),
    ])
  })
  list.each([types.Erlang, types.Node, types.Deno, types.Bun], fn(value) {
    emit(["runtime", outcome.runtime_name(value)])
  })
  list.each(
    [
      types.Killed,
      types.Survived,
      types.TimedOut,
      types.TestError("A"),
      types.TestError("理由"),
    ],
    fn(value) {
      emit([
        "detection",
        outcome_text(value),
        bit(outcome.detected(value)),
        bit(outcome.is_detected(value)),
      ])
    },
  )
}

fn path_checks() -> Nil {
  list.each(
    [
      "",
      "/",
      "/child",
      "/child/",
      "C:/",
      "C:/child",
      "C:/child/",
      "//server/share/",
      "//server/share/child",
      "/a/./b/../c",
      "/../../",
      "C:\\a\\..\\b",
      "\\\\server\\share\\a\\..\\b",
      "/日本 語/../x",
      "a/./../b",
    ],
    fn(value) {
      list.each([False, True], fn(windows) {
        emit([
          "path",
          text_code(value),
          bit(windows),
          text_code(path.from_native(value, windows)),
          text_code(path.normalize_absolute(value, windows)),
          text_code(path.parent(value)),
          text_code(path.base_name(value)),
        ])
      })
    },
  )
}

fn glyph_sequences(length: Int) -> List(List(String)) {
  case length {
    0 -> [[]]
    _ ->
      list.flat_map(["*", "?", "/", "a", "e\u{301}"], fn(head) {
        list.map(glyph_sequences(length - 1), fn(rest) { [head, ..rest] })
      })
  }
}

fn glob_checks() -> Nil {
  list.each([0, 1, 2, 3, 4], fn(length) {
    list.each(glyph_sequences(length), fn(parts) {
      let pattern = string.concat(parts)
      list.each(
        ["", "a", "/", "a/b", "e\u{301}", "a/e\u{301}", "beta"],
        fn(value) {
          emit([
            "glob",
            text_code(pattern),
            text_code(value),
            bit(glob.matches(pattern, value)),
            bit(glob.included(value, [pattern], [pattern])),
          ])
        },
      )
    })
  })
}

fn plan_checks() -> Nil {
  let mutants =
    list.map([#("alpha", "A"), #("alpine", "B"), #("日本", "日")], fn(names) {
      types.Mutant(
        names.0,
        names.1,
        "",
        types.Equality,
        1,
        "",
        span.unsafe_new(0, 0),
        "",
        "",
        "",
        "",
        1,
        1,
      )
    })
  list.each([False, True], fn(changed) {
    list.each(
      [
        None,
        Some(""),
        Some("al"),
        Some("alpha"),
        Some("B"),
        Some("missing"),
        Some("日"),
      ],
      fn(prefix) {
        let prefix_text = case prefix {
          None -> "none"
          Some(value) -> "some:" <> text_code(value)
        }
        let result = case plan.build(mutants, changed, prefix) {
          Ok(value) ->
            plan.mode(value)
            <> ":"
            <> string.join(
              list.map(plan.mutants(value), fn(mutant) { text_code(mutant.id) }),
              ",",
            )
          Error(message) ->
            case string.starts_with(message, "GMU4004:") {
              True -> "missing"
              False ->
                case string.starts_with(message, "GMU4005:") {
                  True -> "ambiguous"
                  False -> "unexpected-error"
                }
            }
        }
        emit(["plan", bit(changed), prefix_text, result])
      },
    )
  })
}

pub fn main() -> Nil {
  span_checks()
  outcome_checks()
  policy_checks()
  identity_checks()
  path_checks()
  glob_checks()
  plan_checks()
}
