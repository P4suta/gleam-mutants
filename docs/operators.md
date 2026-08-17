<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Mutation operators

Version 1.0 provides these versioned operators:

| Operator | Examples |
| --- | --- |
| `boolean-literal` | `True` to `False` |
| `boolean-negation` | remove `!` |
| `boolean-connective` | `&&` to `||` |
| `equality` | `==` to `!=` |
| `comparison-boundary` | `<` to `<=`, `>` to `>=` |
| `integer-arithmetic` | `+`, `-`, `*`, `/`, `%` alternatives |
| `float-arithmetic` | float arithmetic alternatives |
| `integer-neutral` | integer expression to `0` |
| `float-neutral` | float expression to `0.0` |
| `string-neutral` | string expression to `""` |
| `list-neutral` | list expression to `[]` |
| `pipeline-stage-deletion` | remove a Gleam pipeline stage |

Syntactic duplicates and trivial equivalents are deduplicated. Every remaining
candidate is validated by the Gleam compiler; there is no lossy sampling by
default. Stable IDs hash a length-prefixed encoding of normalized path,
operator name/version, source digest, byte span, and original/replacement
digests. The UI starts with a collision-checked 20-character prefix while JSON
retains the full SHA-256 value.
