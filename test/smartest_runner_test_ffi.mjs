// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

export function block(milliseconds) {
  const wait = Math.max(0, Number(milliseconds));
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, wait);
}
