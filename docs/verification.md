<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Verification contracts

Verification is development infrastructure for the mutation engine.
It does not add a test framework or proof service to the published API.
The [package boundary ADR](adr/mutation-testing-package-boundary.md) records this choice.

## Source-derived integer decisions

`mise run prove` reads the current [limits module](../src/gleam_mutants/core/limits.gleam).
The unpublished, dependency-free Rust helper parses a closed Gleam fragment of integer constants, typed comparisons, conjunction, and disjunction.
It lowers those expressions into Lean Boolean decisions over integers.
It rejects additional declarations, missing predicates, unknown names, arithmetic, calls, imports, and unsupported tokens.
Boolean precedence is preserved.
The generated model and the exact source copy are isolated under a fresh `build/verification/` directory.

[Independent contracts](../verification/Contracts.lean) require jobs in 1–32, explicit timeouts in 100–86,400,000 milliseconds, interruption exactly at 130 or 143, and file link counts and compiler rejection statuses exactly equal to one.
Each theorem quantifies over all mathematical integers.
This covers admitted Gleam integer inputs under the compiler's ordinary integer-comparison semantics.
Constants and boundary values are exactly representable on the JavaScript target.
There is no arithmetic overflow in this fragment.
Malformed foreign values such as NaN forged through FFI are outside the typed input domain.

The trusted model link is the reviewed translator, Gleam's compiler, and integer comparison semantics.
The proof is about a source-derived model; Lean does not directly verify Gleam executable code.
Parser tests check production derivation, source-bound changes, Boolean precedence, and refusal of unsupported syntax.
Both Gleam targets compile the same production predicates.

Lean 4.34.1 and elan 4.2.4 are downloaded with pinned SHA-256 checksums in the [proof image](../verification/Dockerfile).
Proof commands run without network access, with two CPUs, 2GiB memory and no additional swap, 256 processes, and a 900-second operational limit.
A resource stop is inconclusive.
The process supervisor terminates and reaps a timed-out client before attempting container cleanup.
Cleanup has a separate ten-second deadline and preserves the primary failure when it also fails.
Native fixtures cover zero-deadline termination, completed statuses, cleanup failure, missing cleanup commands, and a blocked cleanup command.
These checks depend on ordinary OS process termination and Docker daemon behavior.
An inability to terminate a client or remove its container remains a reported failure, never a proof result.
The original six named theorems must have no axioms.
The gate replays all compiled contract modules through a fresh kernel.
It changes one production constant for each predicate and requires the corresponding equality-proof failure against the unchanged contracts.
A successful broken proof or another kind of tool failure fails the gate.
The original production source and independent contracts must still match their copies at completion.
Generated models and logs are evidence for that invocation; later invocations generate fresh evidence.

## Source-derived filename decisions

The gate also reads the complete [filesystem entry module](../src/gleam_mutants/core/filesystem_entry.gleam).
A closed translator admits its typed string inequalities, conjunctions, and negated single-character containment checks.
It refuses other declarations, calls, operators, and literals.
The model represents a string as its sequence of Unicode scalar values.
Empty text, dot, and parent components become empty, singleton, and two-element lists.
Slash, backslash, and NUL containment become membership of their scalar values.
The independent contract quantifies over every finite list of natural numbers, including all Unicode scalar sequences.
This representation uses constructive list operations and needs no additional axioms.
The reviewed translation and ordinary Gleam equality and containment semantics remain trusted.
It does not prove an operating system's path resolution or verify Gleam executables directly.

All directory traversal checks the production predicate before joining names or applying exclusions.
An independent executable reference checks every ASCII component of length zero through two, plus Unicode and whitespace controls.
Native regressions cover escaped writes, literal whitespace, source directories named `build`, duplicate and prune refusal, private roots, and active-copy collection.
A Rust fixture runs those boundaries with umask zero on Erlang, Node, Deno, and Bun.
POSIX permission assertions are conditional on the host platform; Windows ACL behavior remains an external assumption.
A synchronized two-process fixture pauses directory creation while another participant populates shared state, then checks that both operations preserve that state.
The [filesystem boundary decision](adr/preserve-filesystem-entry-boundaries.md) records the compatibility and ownership limits.

See Lean's [proof validation documentation](https://lean-lang.org/doc/reference/latest/ValidatingProofs/) for the distinction between elaboration and kernel replay.

## Source-derived pure core

The [pure core decision](adr/derive-pure-core-contracts-from-source.md) extends the same gate beyond input admission.
The required sources, theorem names, permitted logical axioms, and rejecting controls are maintained in the [executable inventory](../verification/src/contracts.rs).
Missing theorems, unapproved dependencies, source changes during a run, or successful broken controls fail the gate.
All models and contracts are copied into a fresh evidence directory before checking.

| Production module | Independent contracts | Model domain and boundary |
| --- | --- | --- |
| `core/span` | [SpanContracts](../verification/SpanContracts.lean) | Prioritized construction errors, accessors, length, equality, containment, overlap, strict containment, and total ordering over mathematical integers |
| `core/outcome` | [OutcomeContracts](../verification/OutcomeContracts.lean) | Detection agreement, the first error and its complete payload, empty evidence, and survival/timeout priority over arbitrary finite lists |
| `core/score` | [ScoringContracts](../verification/ScoringContracts.lean) | Nonnegative integer counts, partition, conservation, detected counts, zero denominator, and the symbolic percentage numerator and denominator |
| `core/exit_policy` | [ScoringContracts](../verification/ScoringContracts.lean) | Every integer error count, optional strict override, and Boolean threshold-comparison result |
| `core/operator` | [SelectionContracts](../verification/SelectionContracts.lean) | Complete and duplicate-free enum inventory, injective names, name parsing round trips, and the current operator version |
| `core/plan` | [SelectionContracts](../verification/SelectionContracts.lean) | Full/changed preservation, exact one-match admission, missing and ambiguous refusal, prefix membership, and source order for arbitrary finite lists |
| `core/path` | [PathContracts](../verification/PathContracts.lean) | Native separator conversion, component-stack invariants and idempotence, parent removal, joining, and POSIX, drive, and UNC root construction |
| `core/glob` | [GlobContracts](../verification/GlobContracts.lean) | Terminating wildcard recursion, empty patterns, globstar directory boundaries, zero-directory matching, question marks, slash barriers, and exclusion priority over arbitrary finite grapheme-symbol lists |

The span translator admits typed arithmetic, Boolean expressions, constructors, projections, calls among the admitted functions, and exhaustive Boolean cases.
It checks the complete function inventory and rejects recursion, incompatible types, unknown calls, unsupported syntax, and excessive input depth or size.
Other translators use complete [closed syntax rules](../verification/fragments) with explicitly captured values and operators.
An unsupported declaration, reordered control structure, or changed relevant public type is refused rather than silently omitted.
The preserved `core_source` cargo-fuzz corpus replays canonical source round trips in `check-verification`.
The replay requires every named parser family; duplicated seeds cannot compensate for a missing family.

These are theorems about source-derived models, conditional on the reviewed lowering rules and ordinary Gleam compiler and library semantics.
They are not a direct verification of Gleam executables or the translators.
Span arithmetic refines the JavaScript target when the input coordinates and results are exactly represented integers.
Validated nonnegative endpoints within the JavaScript safe-integer range meet that requirement for subtraction.
The BEAM target uses mathematical integer arithmetic for this fragment.
List-count proofs apply while target list lengths and their sums are exactly represented.

Containment is defined by endpoint inequalities, including zero-width spans.
The nonempty-intersection theorem therefore requires both intervals to have positive length.
It does not redefine zero-width spans as invalid or silently assume they cannot be constructed.
`unsafe_new` models successful return or assertion failure; OS termination details remain native behavior.

Outcome payloads and selector prefixes use lists of scalar values.
Runtime metadata is projected away only where the complete source accesses the outcome alone.
Path models represent ASCII separators, dot components, splitting, joining, and root construction explicitly.
Glob symbols classify star, question mark, and slash separately from other complete graphemes.
The glob theorem domain starts after the production path normalization and grapheme conversion.
Unicode segmentation, UTF-8 encoding, string-prefix behavior, and library representations remain refinement assumptions with native checks.
The path component idempotence theorem does not assert that every path spelling has one physical filesystem identity.
The [parent contracts](../verification/ParentContracts.lean) additionally preserve POSIX, ASCII-drive, and nonempty UNC roots and establish decreasing component counts before reaching a root.
The parent model and the production helper use the same root/component split as absolute normalization.
An independent Node comparison checks 2,343 canonical absolute parents across POSIX, drive, and UNC roots.
The [root preservation decision](adr/preserve-lexical-path-roots.md) records the affected callers and compatibility boundary.

Percentage terms retain the actual conversion/division/multiplication order and scale, but do not evaluate binary floating-point rounding.
The numerator is nonnegative and no larger than the positive denominator for a nonzero valid-mutant count.
This mathematical result does not prove every rounded percentage or its display text.
Exit-policy theorems quantify both possible results of the actual floating-point threshold comparison without assuming its truth.
Native score, formatting, configuration-admission, and runtime tests remain required at those boundaries.

The [native model comparison](../test/proof_model_smoke.gleam) checks selected models against production execution on Erlang, Node, Deno, and Bun.
It includes interval endpoints at zero and the shared safe-integer limit, distinct ASCII and Unicode error payloads, all category sequences through length four, integer score fields, percentage boundary checks, and exit-policy cases.
The gate checks each expected record category and compares ordered output with the source-derived Lean evaluator.
Missing, empty, or mismatched records fail.
This finite comparison supports the model link; the general theorems provide the unbounded model properties.
The comparison also covers every operator, runtime name, detection variant, representative prefix selections, path operations, and 5,467 wildcard/grapheme cases.
The directory-boundary regression rejects `**/app.gleam` matching `myapp.gleam`.
The general contract requires `**/` to preserve the remaining pattern's result when the path contains no separator.
Only a consumed directory separator permits the helper to retry that remaining pattern at another position.

The verifier embeds its actual translator sources, syntax rules, inventories, independent contracts, proof image definition, dependency manifests, tool pins, and native comparison fixtures at compilation.
It refuses a checkout that differs from those compiled inputs before deriving a model, before each proof child, and again before reporting a completed proof.
The evidence directory retains these inputs alongside production sources, contracts, axiom reports, native outputs, replay results, and rejecting controls.
An integration fixture runs a compiled verifier against changed configuration and requires the specific stale-source refusal.

## Native boundaries and checked alternatives

No maintained Gleam-native verifier is configured for Glance AST traversal, filesystem operations, or external process trees.
The restricted translator deliberately rejects those semantics.
Encoding their effects as assumptions in Lean would not verify the actual adapter.
The project therefore requires native boundary checks alongside the supported predicate proofs.
Reassess this boundary when a maintained verifier can import the relevant Gleam implementation or when the implementation is decomposed into another supported pure fragment.

| Affected contract | Production path | Required check and boundary |
| --- | --- | --- |
| Option admission | API, engine, configuration, CLI | Source-derived jobs, timeout, and interruption contracts; invalid root, job, timeout, and command regressions |
| Shared API and results | API and canonical types | `api_smoke` compares actual engine scores, selection, policy, identities, and outcomes |
| Diagnostic traceability | Native report projection and schemas | Every outcome category preserves its optional error reason; empty, Unicode, control-character, and escaped messages round-trip through JSON |
| Diagnostic privacy | Execution results and report projections | Real failing processes exercise none, errors, and all modes; suppressed text is absent from API outcomes, native JSON, and Stryker JSON on four runtimes |
| Public package boundary | Package configuration and runtime generator | Exact public-module inventory; generated runtimes preserve explicit, empty, and default internal-module patterns; ordinary tests and mutation dogfood run the same gate |
| Report persistence | API and report adapters | Default no-write and explicit persistence; installed Hex consumer and report storage faults |
| Host preservation | Process FFI, engine, CLI | Child exit 130/143 during compilation, baseline, and mutation batches on all four runtimes; API continuation and CLI exit |
| Process text | Process FFI and report serialization | UTF-8 boundary vectors, BOM preservation, all 65,536 two-byte inputs against Node's replacement decoder, truncated multibyte output, and actual API report serialization on four runtimes |
| Input preservation | Snapshot and instrumenter | Byte digests, spaces, Unicode/CRLF, link rejection, generated-link cleanup, 10,000 fixed-seed properties |
| Filesystem names and privacy | Entry predicate, physical paths, snapshot roots, shared cache | Source-derived scalar-sequence contract; complete two-character ASCII domain; escaped-write controls; four-runtime permissive-umask fixture; synchronized shared-directory creation |
| Absolute workspace identity | Platform path resolution, cache, history, and locks | Dot and parent aliases share an identity; 11,718 rooted paths match Node's independent POSIX and Windows references; drive and UNC roots remain protected |
| Local dependency closure | Local dependency capture and snapshot identity | All 512 directed three-package graphs against an independent transitive-closure reference; shared, absolute, development, Git, retained-copy, and link boundaries; real locked builds and cache invalidation on four runtimes |
| Compiler classification | Validation batches | Source-derived rejection-status contract; mixed and all-rejected catalogues; invalid mutants remain rejected; persistent compiler failures with exit 1 and 75 abort validation on all four runtimes |
| Baseline and aggregation | Execution and outcome core | Baseline failure returns an error; all 341 outcome-category lists of length zero through four match an independent priority reference |
| Selection and cache | Engine, impact protocol, cache | Automatic and full-suite parity, conservative confirmation, all-hit behavior, runtime/compiler identity, source file permissions, and external dependency contents |
| Cleanup and durability | Snapshots, locks, report storage | Source-derived file-link admission; retained-copy file, directory, root symlink, and hard-link refusal; read-only snapshot disposal and external-link permission preservation; process-tree, interruption, workspace-lock, report lifecycle, and storage fault smokes |
| Consumer compatibility | CLI and artifacts | Schema validation, four-runtime report parity, offline browsers, installed Hex API, escript/npm execution, reproducible packages |
| Mutation semantics | Core and engine | Dogfood score mutation and five fixed official-library corpora with exact expected outcomes and source hashes |
| Assurance completeness | Score dogfood runner | Exact admitted and rejected candidate identities, fresh single-runtime measurements, and negative controls for missing, duplicated, cached, timed-out, erroneous, and inconsistent results |

The finite aggregation check covers the engine's one-runtime and four-runtime category domains, including missing evidence.
Diagnostic round trips cover all outcome constructors, all ASCII scalar values, empty reasons, mixed Unicode and escapes, and text exceeding the process output limit.
These are executable JSON-boundary checks, not an unbounded proof of the JSON library.
It is an exhaustive executable check at that bound, not an unbounded theorem about every list length or arbitrary diagnostic text.
The graph check covers every directed graph on three named packages, including self-edges and unreachable cycles.
It checks the actual filesystem adapter against a separately computed reachability relation.
This is a finite executable check, not an induction proof for arbitrary graph size.
A pinned compiler control accepts a POSIX relative dependency path containing a colon before the capture regression checks its package-relative resolution.
Windows drive-prefix interpretation is conditional on the host platform.
Tomlet document editing and recursive filesystem capture remain outside the restricted proof translator's semantics.
Windows Erlang cleanup first attempts ordinary file deletion.
After access denial, it changes the owner-write bit only for a read-only regular file admitted by the source-derived unshared-file predicate.
Symlinks and shared hard links cannot enter that permission-changing path.
The regression tests dispose a read-only snapshot while checking source bytes and permissions, then check read-only external targets behind symbolic and hard links.
The [Windows deletion contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-deletefile) and [Erlang file operations](https://www.erlang.org/doc/apps/kernel/file.html) remain external assumptions.
The platform matrix supplies actual OS evidence for this adapter, rather than a theorem about Windows attributes or concurrent filesystem substitution.
The process-text corpus follows the [UTF-8 replacement decoder](https://encoding.spec.whatwg.org/#utf-8-decoder) and preserves a leading byte order mark as text.
The exhaustive two-byte comparison covers that finite byte domain, and the longer vectors cover valid and malformed three-byte and four-byte boundaries.
Erlang's Unicode decoder and the JavaScript runtime decoders remain external library assumptions.
These native checks do not establish a theorem for arbitrary-length byte streams.
The [local dependency ADR](adr/capture-local-dependencies-in-snapshots.md) records the model boundary and capture decision.
External compiler and OS behavior remain integration assumptions.
Tests cannot establish arbitrary test-program isolation or correctness.
The dogfood runner compares report records and identity lists outside the translator's admitted fragment.
Its negative controls exercise missing or duplicated candidates, unexpected compiler rejections, skipped work, wrong or cached runtimes, timeouts, execution errors, and inconsistent scores.
These finite checks do not prove the runner or compiler correct for every possible report.
Source-derived absolute-path contracts cover lexical component reduction and root construction.
Its fixed reference corpus covers every sequence of zero through five components from node, dot, parent, whitespace, and Unicode controls under three root forms.
It also checks idempotence, root clamping, literal POSIX backslashes, and actual report-history reads through dot and parent aliases.
These checks cover that finite corpus and the native boundaries; symlink aliases and arbitrary filesystem path semantics are not proven.

## Gates

Release automation has a separate pure Rust core in `tools/release-core`.
`mise run prove-release` imports that implementation directly into pinned Kani 0.68.0.
Six harnesses check output reuse, finalization, conclusive runtime counts, release identity selection, phase capabilities, and the distinction between suppressed and actual proposal CI.
They cover every admitted Boolean or enum state and all `u64` count and release-ID combinations in those predicates.
Release selection admits only nonzero IDs, preserves the first match, and refuses another match even when both IDs are equal.
Its harness checks every selection transition and reachability of the missing, unique, and ambiguous states.
The same identity harness checks every `u64` controller run and `u32` attempt, requiring both to be nonzero and preserving both fields.
The production constructor stores the checked values as `NonZeroU64` and `NonZeroU32`.
The phase harness quantifies over all four publication phases and checks the production callback dispatcher.
Hex and npm invoke only the completed-preparation reader; draft and finalization select the GitHub release reader.
Both branches must be reachable, and each dispatch invokes exactly one reader.
The gate requires six successful harnesses and separately rejects seven deliberately broken implementations at the corresponding harness.
Each negative control selects only its named harness and requires its exact failed-harness summary.
Tool failure, an empty harness inventory, or a resource stop supplies no proof result.
The pinned container uses the same bounded supervisor as the Gleam proof gate and records its actual source hash.
These proofs establish the core predicates under Kani's Rust model; they do not verify external I/O or provider semantics.

`mise run check-release` runs strict Rust formatting, Clippy, unit and CLI tests, and the preserved publication-phase and controller-identity fuzz corpus with round-trip properties.
The cargo-fuzz target is `fuzz/fuzz_targets/publication_phase.rs`.
Native regressions cover sealed candidate tampering, missing evidence, source and attempt mismatches, latest-job invalidation, artifact selection, denied local publication, conflicting assets, and recovery after partial uploads.
Draft discovery uses the complete paginated [GitHub release catalogue](https://docs.github.com/en/rest/releases/releases#list-releases), since the release-by-tag endpoint returns published releases.
Native protocol regressions cover a missing published-tag response with an existing draft, exact selection after unrelated records, malformed or duplicated identities, transport failures, and refusal of published targets.
The tag reference remains authoritative for the candidate source; a draft's `target_commitish` may name a branch.
GitHub hides draft releases from tokens without push authority.
Registry phases instead read the successful draft job from their active controller run through Actions read permission.
Native handoff regressions reject foreign controller fields, absent or ambiguous producers, transport failure, and later failed or skipped producers.
A producer from an earlier attempt is reusable only while it remains the latest successful named job in the same controller source and run.
This is evidence about completed preparation, not a claim that a read-only token can inspect the current draft.
Finalization reads the complete current draft and both registry archives again before publication.

The fast release check parses the actual publication YAML with pinned YAML 1.2 tooling and compares its phase permissions with the production evidence routes.
It also checks the complete job inventory, protected environments, candidate argument bindings, readiness dependencies, and failure propagation.
Negative controls reject authority drift, skipped or ignored prerequisites, removal of readiness, secret references in evidence jobs, and changed candidate or producer identities.
The hosted read-only `registry-ready` job executes the same registry planning function as publication without registry credentials before either registry approval becomes available.
GitHub's execution, token permissions, truthful job metadata, YAML interpretation, and external provider availability remain trust assumptions.
These checks do not prove an external service or an atomic transaction across registries.
The pinned GitHub CLI checks the attestation adapter's arguments for SHA-256 and SHA-512 with online and retained-bundle modes.
A malformed custom trust root must fail with the expected parsing error after argument admission.
The test uses isolated configuration and a placeholder token without network access.
The candidate workflow separately requires real retained and online provenance verification with the exact certificate identity, source and signer digests, protected ref, and hosted runner restriction.
GitHub CLI and Sigstore verification remain external trust assumptions.
Proposal CI regressions reject foreign metadata and human approval cases, preserve active or failed runs, and constrain dispatch to the internal bot's version files and exact source.
The protected preparation workflow formats the generated changelog with pinned rumdl before checking CI.
It creates a single-file commit from the inspected proposal source, updates only the fixed bot branch without force, and checks CI at the resulting source.
A native formatter regression checks known entries, blank lines, list markers, empty-input refusal, and idempotence.
Dispatch checks the actual Git branch reference, object type, and exact source after formatting, while the CI workflow checks that source again before checkout.
The PR response still supplies proposal identity but no longer serves as the execution reference after a branch update.
GitHub's event suppression and workflow execution remain external assumptions that require live verification.
`mise run audit-tools` checks the release and fuzz dependency lockfiles against the exact RustSec commit in `tools/release/rustsec.commit`.
Review upstream advisory changes and update that full commit explicitly to renew the shared audit snapshot.

`mise run check` runs compilation, unit tests, documentation, metadata, dependency/security checks, and Rust derivation checks.
`mise run test-integration`, `test-matrix`, `test-property`, `test-faults`, `dogfood`, `test-ecosystem`, and `package` exercise the native obligations above.
Properties use 10,000 cases and seed 24301.
The ecosystem corpus identities and expected outcomes are fixed in the maintained runner.
Score dogfood requires all 50 compiler-admitted candidates to fail the complete Erlang unit suite without cached outcomes.
It compares both the admitted identities and the seven compile-invalid identities with a separate compiler-validation run.
All 57 candidates must appear exactly once in the expected partition.
Six rejected score candidates occur in clause guards, where runtime schemata are unsupported.
The 50 executions do not establish detection at those guard sites.
It checks the individual runtime outcomes independently of the reported score.
Timeouts and execution errors leave this assurance inconclusive, even when the product's ordinary scoring counts a timeout as detected.
The per-mutant limit is one minute, and the campaign limit is 15 minutes with two workers.
Deadlines only stop resource use and never establish a passing verdict.

The manual candidate workflow runs the complete inventory on its exact protected-main source and records fourteen Linux gates and eighteen checks on each of three operating systems.
The publication workflow verifies those retained receipts and bytes instead of rebuilding packages.
The [release guide](releasing.md) defines source, producer-attempt, provenance, and approval checks.
A skipped, empty, failed, or inconclusive required check leaves the corresponding obligation open.
Local macOS results do not establish Linux or Windows behavior, hosted OIDC, signatures, or publication.
