//// Epistemic and execution contracts shared by every Smartest technique.
////
//// This module is deliberately pure and depends only on `gleam_stdlib`.

// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A runtime on which evidence can be collected or replayed.
pub type Target {
  Erlang
  Node
  Deno
  Bun
}

/// An effect a test or resource may require.
pub type Capability {
  FileRead
  FileWrite
  Network
  Subprocess
  Environment
  Clock
  Randomness
  CustomCapability(String)
}

/// The effect grade of an execution plan.
///
/// Exploratory tests are run automatically only when they are `Pure`, or when
/// every declared capability has explicitly been allowed by the runner.
pub type EffectGrade {
  Pure
  Declared(List(Capability))
  Unknown(reason: String)
}

/// A deterministic exploration budget.
pub type Budget {
  Budget(cases: Int, shrinks: Int, timeout_ms: Int, seed: Int)
}

/// The bounded default used by the fast test lane.
pub fn default_budget() -> Budget {
  Budget(cases: 100, shrinks: 500, timeout_ms: 5000, seed: 24_301)
}

/// Constructs a non-negative budget.
pub fn budget(
  cases cases: Int,
  shrinks shrinks: Int,
  timeout_ms timeout_ms: Int,
  seed seed: Int,
) -> Budget {
  Budget(
    cases: non_negative(cases),
    shrinks: non_negative(shrinks),
    timeout_ms: non_negative(timeout_ms),
    seed: seed,
  )
}

fn non_negative(value: Int) -> Int {
  case value < 0 {
    True -> 0
    False -> value
  }
}

/// Where the judgement attached to evidence came from.
pub type OracleProvenance {
  ExampleOracle
  PropertyOracle(name: String)
  ModelOracle(name: String)
  SnapshotOracle(name: String)
  ExternalOracle(name: String)
  HumanOracle(review: String)
  /// A difference was observed, but neither side has been judged correct.
  DifferentialOnly
  /// Current behaviour was recorded without an independent judgement.
  Characterization
  /// A machine generated a proposal. It remains provisional until review.
  AiProposed(OracleProvenance)
}

/// Whether evidence is allowed to gate CI.
pub type Trust {
  Provisional
  Trusted
}

/// The state shown in the evidence ledger.
pub type EvidenceState {
  ProvisionalEvidence
  TrustedEvidence
  UnjudgedDivergence
  StaleEvidence(reason: String)
  UnsafeEvidence(reason: String)
  UnsupportedEvidence(reason: String)
  RejectedEvidence(reason: String)
}

/// A claim that two programs are equivalent, including its formal boundary.
///
/// There is intentionally no constructor for this opaque type. Callers must
/// provide a method, a proved subset and a bound through `formal_proof`.
pub opaque type FormalProof {
  FormalProof(method: String, subset: String, bound: String)
}

/// Why a formal-proof value could not be constructed.
pub type ProofError {
  MissingProofMethod
  MissingProofSubset
  MissingProofBound
}

/// Records a formal equivalence proof and the exact boundary it covers.
pub fn formal_proof(
  method method: String,
  subset subset: String,
  bound bound: String,
) -> Result(FormalProof, ProofError) {
  case string.trim(method), string.trim(subset), string.trim(bound) {
    "", _, _ -> Error(MissingProofMethod)
    _, "", _ -> Error(MissingProofSubset)
    _, _, "" -> Error(MissingProofBound)
    method, subset, bound -> Ok(FormalProof(method, subset, bound))
  }
}

pub fn proof_method(proof: FormalProof) -> String {
  proof.method
}

pub fn proof_subset(proof: FormalProof) -> String {
  proof.subset
}

pub fn proof_bound(proof: FormalProof) -> String {
  proof.bound
}

/// The conservative result of trying to distinguish a verification target.
pub type ExplorationVerdict {
  JudgedWitness(oracle: OracleProvenance)
  UnjudgedWitness
  NotDistinguishedWithinBudget(Budget)
  EquivalentByProof(FormalProof)
  UnreachableUnderSelectedBoundary
  UnsafeToExplore(reason: String)
  UnsupportedTarget(reason: String)
}

/// A stable test identity. Renames are explicit corpus operations, never an
/// accidental consequence of a display label changing.
pub opaque type TestId {
  TestId(
    package: String,
    module: String,
    function: String,
    children: List(String),
  )
}

pub fn test_id(package: String, module: String, function: String) -> TestId {
  TestId(package, module, function, [])
}

pub fn child_test_id(parent: TestId, name: String) -> TestId {
  TestId(..parent, children: list.append(parent.children, [name]))
}

pub fn test_id_package(id: TestId) -> String {
  id.package
}

pub fn test_id_module(id: TestId) -> String {
  id.module
}

pub fn test_id_function(id: TestId) -> String {
  id.function
}

pub fn test_id_children(id: TestId) -> List(String) {
  id.children
}

/// Canonical, reversible text used as a corpus key.
pub fn test_id_to_string(id: TestId) -> String {
  [id.package, id.module, id.function, ..id.children]
  |> list.map(escape_id_part)
  |> string.join("/")
}

pub fn test_id_from_string(value: String) -> Result(TestId, String) {
  case string.split(value, "/") {
    [package, module, function, ..children] -> {
      let root =
        test_id(
          unescape_id_part(package),
          unescape_id_part(module),
          unescape_id_part(function),
        )
      Ok(
        list.fold(children, root, fn(parent, child) {
          child_test_id(parent, unescape_id_part(child))
        }),
      )
    }
    _ -> Error("test id must contain package/module/function")
  }
}

/// Content-derived id for a replay witness. A collision is never overwritten;
/// the storage shell reports it as a conflict.
pub fn finding_id(
  id: TestId,
  generator_schema: String,
  tape: List(Int),
) -> String {
  let source =
    test_id_to_string(id)
    <> "\n"
    <> generator_schema
    <> "\n"
    <> string.join(list.map(tape, int.to_string), ",")
  "finding-" <> int.to_string(hash_text(source, 17))
}

fn hash_text(value: String, accumulator: Int) -> Int {
  case string.to_utf_codepoints(value) {
    [] -> accumulator
    [code, ..rest] -> {
      let next =
        { accumulator * 131 + string.utf_codepoint_to_int(code) }
        % 2_147_483_647
      hash_codepoints(rest, next)
    }
  }
}

fn hash_codepoints(codes: List(UtfCodepoint), accumulator: Int) -> Int {
  case codes {
    [] -> accumulator
    [code, ..rest] ->
      hash_codepoints(
        rest,
        { accumulator * 131 + string.utf_codepoint_to_int(code) }
          % 2_147_483_647,
      )
  }
}

fn escape_id_part(part: String) -> String {
  part
  |> string.replace("%", "%25")
  |> string.replace("/", "%2F")
}

fn unescape_id_part(part: String) -> String {
  part |> string.replace("%2F", "/") |> string.replace("%25", "%")
}

/// True only for an oracle that judges behaviour independently of an
/// original-versus-mutant difference.
pub fn oracle_is_independent(oracle: OracleProvenance) -> Bool {
  case oracle {
    ExampleOracle
    | PropertyOracle(_)
    | ModelOracle(_)
    | SnapshotOracle(_)
    | ExternalOracle(_)
    | HumanOracle(_) -> True
    DifferentialOnly | Characterization | AiProposed(_) -> False
  }
}

/// The initial ledger state for a newly observed finding.
pub fn initial_state(oracle: OracleProvenance) -> EvidenceState {
  case oracle {
    DifferentialOnly -> UnjudgedDivergence
    _ -> ProvisionalEvidence
  }
}

/// A reviewed finding may become trusted only with an independent oracle.
pub fn review(
  state: EvidenceState,
  oracle: OracleProvenance,
  human_oracle: Option(String),
) -> #(EvidenceState, OracleProvenance) {
  let oracle = case human_oracle {
    Some(note) -> HumanOracle(note)
    None -> oracle
  }
  case state, oracle_is_independent(oracle) {
    ProvisionalEvidence, True | UnjudgedDivergence, True -> #(
      TrustedEvidence,
      oracle,
    )
    ProvisionalEvidence, False -> #(ProvisionalEvidence, oracle)
    UnjudgedDivergence, False -> #(UnjudgedDivergence, oracle)
    _, _ -> #(state, oracle)
  }
}

/// Only trusted failures and stale accepted evidence block the default CI
/// lane. A new survivor or provisional proposal is advisory.
pub fn blocks_ci(state: EvidenceState) -> Bool {
  case state {
    TrustedEvidence | StaleEvidence(_) -> True
    ProvisionalEvidence
    | UnjudgedDivergence
    | UnsafeEvidence(_)
    | UnsupportedEvidence(_)
    | RejectedEvidence(_) -> False
  }
}

/// Checks whether an exploratory plan may run under the supplied grants.
pub fn exploration_allowed(
  grade: EffectGrade,
  granted: List(Capability),
) -> Bool {
  case grade {
    Pure -> True
    Unknown(_) -> False
    Declared(required) ->
      list.all(required, fn(capability) { list.contains(granted, capability) })
  }
}

pub fn target_name(target: Target) -> String {
  case target {
    Erlang -> "erlang"
    Node -> "node"
    Deno -> "deno"
    Bun -> "bun"
  }
}

pub fn target_from_name(name: String) -> Option(Target) {
  case string.lowercase(name) {
    "erlang" -> Some(Erlang)
    "node" -> Some(Node)
    "deno" -> Some(Deno)
    "bun" -> Some(Bun)
    _ -> None
  }
}

pub fn capability_name(capability: Capability) -> String {
  case capability {
    FileRead -> "file-read"
    FileWrite -> "file-write"
    Network -> "network"
    Subprocess -> "subprocess"
    Environment -> "environment"
    Clock -> "clock"
    Randomness -> "randomness"
    CustomCapability(name) -> name
  }
}

pub fn capability_from_name(name: String) -> Capability {
  case string.lowercase(name) {
    "file-read" -> FileRead
    "file-write" -> FileWrite
    "network" -> Network
    "subprocess" -> Subprocess
    "environment" -> Environment
    "clock" -> Clock
    "randomness" -> Randomness
    other -> CustomCapability(other)
  }
}
