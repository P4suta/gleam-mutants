<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Mutation operators

Version 0.1 provides these versioned operators, each at version 1:

| Operator | Examples |
| --- | --- |
| `boolean-literal` | `True` to `False` |
| `boolean-negation` | remove `!` |
| `boolean-connective` | `&&` to `||` |
| `equality` | `==` to `!=` |
| `comparison-boundary` | `<` to `<=`, `>` to `>=` |
| `integer-arithmetic` | `+`, `-`, `*`, `/`, `%` alternatives |
| `float-arithmetic` | float arithmetic alternatives |
| `integer-neutral` | integer literal to `0` (or `1` when it is already `0`) |
| `float-neutral` | float literal to `0.0` (or `1.0` when it is already `0.0`) |
| `string-neutral` | string literal to `""` (or `"mutant"` when it is already empty) |
| `list-neutral` | non-empty list literal to `[]` |
| `option-neutral` | `Some(x)` to `None`, spelled as the module can |
| `pipeline-stage-deletion` | remove a Gleam pipeline stage |
| `concatenation-operand` | `a <> b` to `a`, and to `b` |

Syntactic duplicates and trivial equivalents are deduplicated. `run` and
`list --validate` validate every remaining candidate with the Gleam compiler;
plain `list` intentionally returns unvalidated discovery candidates. There is
no lossy sampling by default. Stable IDs hash a length-prefixed encoding of
normalized path, operator name/version, source digest, byte span, and
original/replacement digests. The UI starts with a 20-character prefix extended
as needed to avoid collisions across the complete selected catalogue, while
JSON retains the full SHA-256 value.

Neutral operators are literal-focused, with one exception. Semantic rules are
emitted only where Glance provides definite evidence: a literal, a typed binary
operator, or a constructor that fixes the type by itself. `Some(x)` is the last
of those -- it is definitely an `Option`, so `None` is definitely the same
type, and the mutant asks whether anything tests the absence. `Ok` and `Error`
have no such evidence, because their two type arguments need not agree, so a
`Result` that is built is left alone rather than mutated on a hunch.

The replacement is spelled the way the module being scanned can write it,
which is read off its imports: `import gleam/option.{Some, None}` gets a bare
`None`, `import gleam/option.{Some}` gets `option.None` because a bare one
would not be in scope, and either name is taken from the alias where the
import renamed it. A module declaring both variants itself -- `gleam/option`
under its own test suite, or a module that writes its own option out longhand
-- gets its own `None`. A constructor that merely shares the name `Some` with
no absence beside it yields no candidate at all, since there is nothing
writable to swap in.

`<>` is evidence of the same kind: it joins two strings, so each half is
definitely a string and definitely the same type as the whole, and either half
can stand where the join stood. Dropping one asks whether anything checks that
the other reaches the answer.

An arbitrary expression is not treated as an integer, float, string, list, or
option by guesswork. Candidates that are emitted but fail compiler validation
remain visible as rejected candidates with a normalized diagnostic in validated
list and run output; this does not change native report v1 or stable mutant
IDs.
