//// Coverage- and compare-guided exploration on deterministic generator tapes.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import smartest/evidence
import smartest/gen.{type Generator, type Tape, type Tree}
import smartest/internal/plan
import smartest/testing.{type Test}

/// Stable instrumentation ids reached by one case, plus comparison distances
/// keyed by stable comparison-site id. Smaller distances are more useful.
pub type Feedback {
  Feedback(edges: List(Int), comparisons: List(#(Int, Int)))
}

/// Pure accumulated guidance. It is target-independent when instrumentation
/// emits the same stable ids on every target.
pub opaque type Guidance {
  Guidance(edges: List(Int), comparisons: List(#(Int, Int)))
}

type State {
  State(
    seed: Int,
    queued: List(Tape),
    corpus: List(Tape),
    guidance: Guidance,
    remaining: Int,
    completed: Int,
    iteration: Int,
  )
}

type Candidate(a) {
  Candidate(tree: Tree(a), next_seed: Int, queued: List(Tape))
}

pub fn feedback(
  edges edges: List(Int),
  comparisons comparisons: List(#(Int, Int)),
) -> Feedback {
  Feedback(edges, comparisons)
}

pub fn new_guidance() -> Guidance {
  Guidance([], [])
}

/// Records feedback and says whether it adds an edge or improves a distance.
pub fn record_feedback(
  guidance: Guidance,
  feedback: Feedback,
) -> #(Guidance, Bool) {
  let novel_edges =
    feedback.edges
    |> list.unique
    |> list.filter(fn(edge) { !list.contains(guidance.edges, edge) })
  let #(comparisons, comparison_improved) =
    record_comparisons(feedback.comparisons, guidance.comparisons, False)
  #(
    Guidance(
      edges: list.append(guidance.edges, novel_edges),
      comparisons: comparisons,
    ),
    novel_edges != [] || comparison_improved,
  )
}

/// Explores with replayable seeds and deterministic mutations of useful tapes.
///
/// `feedback` must be a total observation of compiler/runtime trace data. The
/// property remains the independent oracle. A malformed seed is stale evidence
/// rather than an input that is silently discarded.
pub fn for_all(
  generator: Generator(a),
  seeds seeds: List(Tape),
  feedback feedback_for: fn(a) -> Feedback,
  property property: fn(a) -> Nil,
) -> Test {
  let schema = gen.schema_fingerprint(generator)
  plan.exploration(
    fn(evaluate, budget, replay) {
      case replay {
        Some(plan.Replay(tape, stored_schema)) ->
          replay_case(
            generator,
            feedback_for,
            property,
            evaluate,
            budget.timeout_ms,
            tape,
            stored_schema,
          )
        None ->
          search(
            generator,
            feedback_for,
            property,
            evaluate,
            budget,
            State(
              seed: budget.seed,
              queued: seeds,
              corpus: list.unique(seeds),
              guidance: new_guidance(),
              remaining: budget.cases,
              completed: 0,
              iteration: 0,
            ),
          )
      }
    },
    Some(schema),
  )
  |> testing.with_oracle(evidence.PropertyOracle("coverage-guided fuzz"))
}

fn replay_case(
  generator: Generator(a),
  feedback_for: fn(a) -> Feedback,
  property: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  timeout_ms: Int,
  tape: Tape,
  stored_schema: String,
) -> plan.CheckResult {
  let schema = gen.schema_fingerprint(generator)
  case schema == stored_schema {
    False ->
      plan.CheckStale(
        "generator schema changed: expected "
        <> stored_schema
        <> ", found "
        <> schema,
      )
    True ->
      case gen.replay(generator, tape) {
        Error(error) ->
          plan.CheckStale(
            "fuzz replay tape no longer decodes: " <> string.inspect(error),
          )
        Ok(tree) -> {
          let _ = feedback_for(gen.tree_value(tree))
          evaluation_result(
            evaluate(fn() { property(gen.tree_value(tree)) }, timeout_ms),
            generator,
            tree,
            1,
            0,
          )
        }
      }
  }
}

fn search(
  generator: Generator(a),
  feedback_for: fn(a) -> Feedback,
  property: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  budget: evidence.Budget,
  state: State,
) -> plan.CheckResult {
  case state.remaining <= 0 {
    True -> plan.CheckPassed(state.completed)
    False ->
      case next_candidate(generator, state) {
        Error(error) ->
          plan.CheckStale(
            "fuzz seed no longer decodes: " <> string.inspect(error),
          )
        Ok(Candidate(tree, next_seed, queued)) -> {
          let value = gen.tree_value(tree)
          let observed = feedback_for(value)
          let #(guidance, interesting) =
            record_feedback(state.guidance, observed)
          let tape = gen.tree_tape(tree)
          let corpus = case interesting && !list.contains(state.corpus, tape) {
            True -> list.append(state.corpus, [tape])
            False -> state.corpus
          }
          let evaluation = evaluate(fn() { property(value) }, budget.timeout_ms)
          case evaluation {
            plan.EvaluationPassed(_) ->
              search(
                generator,
                feedback_for,
                property,
                evaluate,
                budget,
                State(
                  seed: next_seed,
                  queued: queued,
                  corpus: corpus,
                  guidance: guidance,
                  remaining: state.remaining - 1,
                  completed: state.completed + 1,
                  iteration: state.iteration + 1,
                ),
              )
            _ -> {
              let #(smallest, final_evaluation, shrinks) =
                shrink(
                  tree,
                  evaluation,
                  property,
                  evaluate,
                  budget.timeout_ms,
                  budget.shrinks,
                  0,
                )
              evaluation_result(
                final_evaluation,
                generator,
                smallest,
                state.completed + 1,
                shrinks,
              )
            }
          }
        }
      }
  }
}

fn next_candidate(
  generator: Generator(a),
  state: State,
) -> Result(Candidate(a), gen.ReplayError) {
  case state.queued {
    [tape, ..queued] -> {
      use tree <- result.map(gen.replay(generator, tape))
      Candidate(tree, state.seed, queued)
    }
    [] ->
      case guided_tree(generator, state.corpus, state.iteration) {
        Some(tree) -> Ok(Candidate(tree, state.seed, []))
        None -> {
          use generated <- result.map(gen.generate(generator, state.seed))
          let gen.Generated(tree, next_seed) = generated
          Candidate(tree, next_seed, [])
        }
      }
  }
}

fn guided_tree(
  generator: Generator(a),
  corpus: List(Tape),
  iteration: Int,
) -> Option(Tree(a)) {
  case value_at(corpus, modulo(iteration, list.length(corpus))) {
    None -> None
    Some([]) -> None
    Some(tape) -> {
      let position = modulo(iteration, list.length(tape))
      case value_at(tape, position) {
        None -> None
        Some(original) ->
          [0, original / 2, original + 1]
          |> list.unique
          |> list.filter(fn(candidate) { candidate != original })
          |> replay_first(generator, tape, position)
      }
    }
  }
}

fn replay_first(
  choices: List(Int),
  generator: Generator(a),
  tape: Tape,
  position: Int,
) -> Option(Tree(a)) {
  case choices {
    [] -> None
    [choice, ..rest] ->
      case gen.replay(generator, replace_at(tape, position, choice)) {
        Ok(tree) -> Some(tree)
        Error(_) -> replay_first(rest, generator, tape, position)
      }
  }
}

fn shrink(
  tree: Tree(a),
  failure: plan.Evaluation,
  property: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  timeout_ms: Int,
  remaining: Int,
  attempted: Int,
) -> #(Tree(a), plan.Evaluation, Int) {
  case remaining <= 0 {
    True -> #(tree, failure, attempted)
    False ->
      case
        first_failing_child(
          gen.tree_children(tree),
          property,
          evaluate,
          timeout_ms,
          remaining,
          0,
        )
      {
        None -> #(tree, failure, attempted)
        Some(#(child, child_failure, spent)) ->
          shrink(
            child,
            child_failure,
            property,
            evaluate,
            timeout_ms,
            remaining - spent,
            attempted + spent,
          )
      }
  }
}

fn first_failing_child(
  children: List(Tree(a)),
  property: fn(a) -> Nil,
  evaluate: plan.Evaluator,
  timeout_ms: Int,
  remaining: Int,
  spent: Int,
) -> Option(#(Tree(a), plan.Evaluation, Int)) {
  case children, remaining <= 0 {
    _, True | [], _ -> None
    [child, ..rest], False -> {
      let evaluation =
        evaluate(fn() { property(gen.tree_value(child)) }, timeout_ms)
      case evaluation {
        plan.EvaluationPassed(_) ->
          first_failing_child(
            rest,
            property,
            evaluate,
            timeout_ms,
            remaining - 1,
            spent + 1,
          )
        _ -> Some(#(child, evaluation, spent + 1))
      }
    }
  }
}

fn evaluation_result(
  evaluation: plan.Evaluation,
  generator: Generator(a),
  tree: Tree(a),
  cases: Int,
  shrinks: Int,
) -> plan.CheckResult {
  case evaluation {
    plan.EvaluationPassed(_) -> plan.CheckPassed(cases)
    plan.EvaluationFailed(message, _) ->
      plan.CheckFailed(
        message: message,
        witness: Some(gen.render(generator, gen.tree_value(tree))),
        tape: gen.tree_tape(tree),
        generator_schema: Some(gen.schema_fingerprint(generator)),
        cases: cases,
        shrinks: shrinks,
      )
    plan.EvaluationTimedOut(message, _) -> plan.CheckTimedOut(message, cases)
    plan.EvaluationCancelled(message, _) -> plan.CheckCancelled(message, cases)
  }
}

fn record_comparisons(
  observed: List(#(Int, Int)),
  best: List(#(Int, Int)),
  improved: Bool,
) -> #(List(#(Int, Int)), Bool) {
  case observed {
    [] -> #(best, improved)
    [#(site, distance), ..rest] ->
      case best_distance(best, site) {
        Some(current) if distance >= current ->
          record_comparisons(rest, best, improved)
        _ ->
          record_comparisons(
            rest,
            [#(site, distance), ..remove_site(best, site)],
            True,
          )
      }
  }
}

fn best_distance(values: List(#(Int, Int)), site: Int) -> Option(Int) {
  case values {
    [] -> None
    [#(candidate, distance), ..] if candidate == site -> Some(distance)
    [_, ..rest] -> best_distance(rest, site)
  }
}

fn remove_site(values: List(#(Int, Int)), site: Int) -> List(#(Int, Int)) {
  list.filter(values, fn(entry) { entry.0 != site })
}

fn value_at(values: List(a), index: Int) -> Option(a) {
  case values, index {
    _, index if index < 0 -> None
    [], _ -> None
    [value, ..], 0 -> Some(value)
    [_, ..rest], index -> value_at(rest, index - 1)
  }
}

fn replace_at(values: List(Int), index: Int, replacement: Int) -> List(Int) {
  case values, index {
    [], _ -> []
    [_, ..rest], 0 -> [replacement, ..rest]
    [value, ..rest], index -> [
      value,
      ..replace_at(rest, index - 1, replacement)
    ]
  }
}

fn modulo(value: Int, divisor: Int) -> Int {
  case divisor <= 0 {
    True -> 0
    False -> value % divisor
  }
}
