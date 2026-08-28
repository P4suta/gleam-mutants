//// Rule-based state-machine checks built on the shared generator engine.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import smartest/evidence.{type Capability}
import smartest/gen.{type Generator}
import smartest/property
import smartest/testing.{type Test}

pub opaque type Machine(model, sut, command) {
  Machine(
    initial_model: model,
    initial_sut: sut,
    commands: Generator(command),
    precondition: fn(model, command) -> Bool,
    transition: fn(model, command) -> model,
    step: fn(sut, command) -> Result(sut, String),
    invariant: fn(model, sut) -> Bool,
    cleanup: fn(sut) -> Result(Nil, String),
    capabilities: List(Capability),
  )
}

pub fn machine(
  initial_model initial_model: model,
  initial_sut initial_sut: sut,
  commands commands: Generator(command),
  precondition precondition: fn(model, command) -> Bool,
  transition transition: fn(model, command) -> model,
  step step: fn(sut, command) -> Result(sut, String),
  invariant invariant: fn(model, sut) -> Bool,
) -> Machine(model, sut, command) {
  Machine(
    initial_model,
    initial_sut,
    commands,
    precondition,
    transition,
    step,
    invariant,
    fn(_) { Ok(Nil) },
    [],
  )
}

/// Builds a machine with an explicit final-state cleanup contract.
pub fn machine_with_cleanup(
  initial_model initial_model: model,
  initial_sut initial_sut: sut,
  commands commands: Generator(command),
  precondition precondition: fn(model, command) -> Bool,
  transition transition: fn(model, command) -> model,
  step step: fn(sut, command) -> Result(sut, String),
  invariant invariant: fn(model, sut) -> Bool,
  cleanup cleanup: fn(sut) -> Result(Nil, String),
  capabilities capabilities: List(Capability),
) -> Machine(model, sut, command) {
  Machine(
    initial_model,
    initial_sut,
    commands,
    precondition,
    transition,
    step,
    invariant,
    cleanup,
    capabilities,
  )
}

/// Explores and shrinks command sequences. Commands whose precondition is not
/// met are ignored; generated witnesses contain the full attempted sequence.
pub fn check(
  machine: Machine(model, sut, command),
  max_commands max_commands: Int,
) -> Test {
  let value =
    property.for_all(
      gen.list_with_max(machine.commands, max_commands),
      fn(commands) {
        let #(outcome, final_sut) =
          run_commands(
            machine,
            commands,
            machine.initial_model,
            machine.initial_sut,
            0,
          )
        let cleanup = machine.cleanup(final_sut)
        case outcome, cleanup {
          Ok(Nil), Ok(Nil) -> Nil
          Error(reason), Ok(Nil) -> panic as reason
          Ok(Nil), Error(reason) ->
            panic as { "model cleanup failed: " <> reason }
          Error(reason), Error(cleanup_reason) ->
            panic as { reason <> "\nmodel cleanup failed: " <> cleanup_reason }
        }
      },
    )
    |> testing.with_oracle(evidence.ModelOracle("state machine"))
  case machine.capabilities {
    [] -> value
    capabilities -> testing.with_effect(value, evidence.Declared(capabilities))
  }
}

fn run_commands(
  machine: Machine(model, sut, command),
  commands: List(command),
  reference: model,
  sut: sut,
  index: Int,
) -> #(Result(Nil, String), sut) {
  case commands {
    [] -> #(Ok(Nil), sut)
    [command, ..rest] ->
      case machine.precondition(reference, command) {
        False -> run_commands(machine, rest, reference, sut, index + 1)
        True ->
          case machine.step(sut, command) {
            Error(reason) -> #(
              Error(
                "model command "
                <> gen.render(machine.commands, command)
                <> " failed at index "
                <> int.to_string(index)
                <> ": "
                <> reason,
              ),
              sut,
            )
            Ok(next_sut) -> {
              let next_reference = machine.transition(reference, command)
              case machine.invariant(next_reference, next_sut) {
                False -> #(
                  Error(
                    "model invariant failed after command "
                    <> gen.render(machine.commands, command)
                    <> " at index "
                    <> int.to_string(index),
                  ),
                  next_sut,
                )
                True ->
                  run_commands(
                    machine,
                    rest,
                    next_reference,
                    next_sut,
                    index + 1,
                  )
              }
            }
          }
      }
  }
}
