// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// The three parsers below all read one JSON value the CLI printed, and all
// fail the same way when it is not one. Shared so that a caller who catches
// the error sees the same wording whichever document it was.

/**
 * Narrows `value` to a JSON object: not `null`, and not an array.
 *
 * @param value - Anything `JSON.parse` may have produced.
 * @returns True when `value` can be indexed by field name.
 */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * The first `limit` characters of `text`, with an ellipsis when it was cut.
 *
 * Long CLI output is quoted back in error messages; a whole mutation report
 * in a notification would be unreadable.
 *
 * @param text - The stream, or document, to quote.
 * @param limit - How many characters to keep. Defaults to 200.
 * @returns The excerpt, or `(empty)` when there was nothing to quote.
 */
export function excerpt(text: string, limit = 200): string {
  if (text === "") return "(empty)";
  return text.length <= limit ? text : `${text.slice(0, limit)}…`;
}

/**
 * Parses one JSON value, naming the document in the error.
 *
 * @param text - The document, leading and trailing whitespace allowed.
 * @param what - What the document was meant to be, for the error message.
 * @returns The parsed value, of whatever shape the text held.
 * @throws When `text` is not one JSON value.
 */
export function parseJsonValue(text: string, what: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    throw new Error(
      `${what} is not valid JSON (${reason}): ${excerpt(text.trim())}`,
    );
  }
}

/**
 * Parses one JSON object, naming the document in the error.
 *
 * @param text - The document, leading and trailing whitespace allowed.
 * @param what - What the document was meant to be, for the error message.
 * @returns The parsed object.
 * @throws When `text` is not JSON, or is JSON that is not an object.
 */
export function parseJsonObject(
  text: string,
  what: string,
): Record<string, unknown> {
  const value = parseJsonValue(text, what);
  if (!isRecord(value)) {
    throw new Error(`${what}: expected a JSON object, got ${describe(value)}`);
  }
  return value;
}

/**
 * A short name for a JSON value's shape, for use in an error message.
 *
 * @param value - Anything `JSON.parse` may have produced.
 * @returns One word: `null`, `a list`, or the `typeof` of the value.
 */
export function describe(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "a list";
  return typeof value;
}
