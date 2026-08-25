// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// Reading the files that are the deliverable rather than the code: the
// extension manifest, the sources under `src/`, and the repository that
// ships them.

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** An absolute path inside `editors/vscode`. */
export function extensionPath(relative: string): string {
  return fileURLToPath(new URL(`../${relative}`, import.meta.url));
}

/** An absolute path inside the repository that holds the extension. */
export function repoPath(relative: string): string {
  return fileURLToPath(new URL(`../../../${relative}`, import.meta.url));
}

export function extensionFile(relative: string): string {
  return readFileSync(extensionPath(relative), "utf8");
}

export function repoFile(relative: string): string {
  return readFileSync(repoPath(relative), "utf8");
}

export function extensionHas(relative: string): boolean {
  return existsSync(extensionPath(relative));
}

/** The `.ts` modules of one directory under `src/`, sorted. */
export function modulesOf(relative: string): string[] {
  if (!extensionHas(relative)) return [];
  return readdirSync(extensionPath(relative))
    .filter((name) => name.endsWith(".ts"))
    .sort();
}

export interface Manifest {
  readonly main?: string;
  readonly activationEvents?: readonly string[];
  readonly scripts?: Readonly<Record<string, string>>;
  readonly devDependencies?: Readonly<Record<string, string>>;
  readonly dependencies?: Readonly<Record<string, string>>;
  readonly engines?: Readonly<Record<string, string>>;
  readonly contributes?: {
    readonly commands?: ReadonlyArray<{
      readonly command: string;
      readonly title: string;
      readonly category?: string;
    }>;
    readonly configuration?: {
      readonly title?: string;
      readonly properties?: Readonly<
        Record<string, Record<string, unknown>>
      >;
    };
  };
}

/** `editors/vscode/package.json`, parsed. */
export function manifest(): Manifest {
  return JSON.parse(extensionFile("package.json")) as Manifest;
}

/** Every command id the manifest contributes, in the order it lists them. */
export function contributedCommands(): string[] {
  return (manifest().contributes?.commands ?? []).map(
    (command) => command.command,
  );
}
