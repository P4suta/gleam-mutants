<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Mutation operators

Version 0.1 provides these versioned operators:

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
| `pipeline-stage-deletion` | remove a Gleam pipeline stage |

Syntactic duplicates and trivial equivalents are deduplicated. Every remaining
candidate is validated by the Gleam compiler; there is no lossy sampling by
default. Stable IDs hash a length-prefixed encoding of normalized path,
operator name/version, source digest, byte span, and original/replacement
digests. The UI starts with a collision-checked 20-character prefix while JSON
retains the full SHA-256 value.

Neutral operators are currently literal-focused. Semantic rules are emitted
only where Glance provides definite evidence, such as a literal or a typed
binary operator. An arbitrary expression is not treated as an integer, float,
string, or list by guesswork. Candidates that are emitted but fail compiler
validation remain visible as rejected candidates with their diagnostic; this
does not change native report v1 or stable mutant IDs.
