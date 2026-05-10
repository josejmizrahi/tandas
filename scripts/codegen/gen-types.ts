// CLI entry point for the codegen.
//
// Discovers all *.swift files under the source dir, parses those that
// have the // @codegen:enum marker, and writes the generated Swift and
// TS counterparts. Files without the marker are silently skipped (so
// the lefthook glob can be a wildcard without errors).
//
// Modes:
//   --check (default off): does not write; reports any files whose
//     re-rendered content differs from disk. Used by CI.

import { type EnumDecl, parseEnumFile } from "./parser.ts";
import { emitSwift } from "./emit-swift.ts";
import { emitTs } from "./emit-ts.ts";

const DEFAULT_REPO_ROOT = (() => {
  // Resolve to two parents of this script: scripts/codegen/ → scripts/ → repo root.
  const here = new URL(".", import.meta.url).pathname;
  return here.replace(/\/scripts\/codegen\/?$/, "");
})();

// Post-SPM-split paths. Source enums live in RuulCore package; generated
// Codable extensions go to a sibling Generated/ subdir.
const DEFAULT_SOURCE_DIR = `${DEFAULT_REPO_ROOT}/ios/Packages/RuulCore/Sources/RuulCore/PlatformModels`;
const DEFAULT_SWIFT_OUT = `${DEFAULT_SOURCE_DIR}/Generated`;
const DEFAULT_TS_OUT = `${DEFAULT_REPO_ROOT}/supabase/functions/_shared/types`;

export interface GenerateOpts {
  repoRoot: string;
  sourceDir: string;
  swiftOutDir: string;
  tsOutDir: string;
  mode: "write" | "check";
}

export interface GenerateResult {
  processed: string[]; // typeNames
  skipped: string[]; // file paths
  stale: string[]; // output paths that differ (check mode)
}

const MARKER = "// @codegen:enum";

export async function generate(opts: GenerateOpts): Promise<GenerateResult> {
  const result: GenerateResult = { processed: [], skipped: [], stale: [] };

  for await (const entry of Deno.readDir(opts.sourceDir)) {
    if (!entry.isFile || !entry.name.endsWith(".swift")) continue;
    if (entry.name === "Generated" || entry.name.endsWith("+Extensions.swift")) continue;

    const path = `${opts.sourceDir}/${entry.name}`;
    const text = await Deno.readTextFile(path);
    if (!text.split(/\r?\n/).slice(0, 20).some((l) => l.trim() === MARKER)) {
      result.skipped.push(path);
      continue;
    }

    let decl: EnumDecl;
    try {
      decl = await parseEnumFile(path);
    } catch (e) {
      throw new Error(
        `parser failed on ${path}: ${e instanceof Error ? e.message : String(e)}`,
      );
    }

    const swiftOut = `${opts.swiftOutDir}/${decl.typeName}+Codable.swift`;
    const tsOut = `${opts.tsOutDir}/${lowerFirst(decl.typeName)}.ts`;

    const swiftContent = emitSwift(decl);
    const tsContent = emitTs(decl);

    if (opts.mode === "check") {
      if (await diffs(swiftOut, swiftContent)) result.stale.push(swiftOut);
      if (await diffs(tsOut, tsContent)) result.stale.push(tsOut);
    } else {
      await Deno.writeTextFile(swiftOut, swiftContent);
      await Deno.writeTextFile(tsOut, tsContent);
    }
    result.processed.push(decl.typeName);
  }

  return result;
}

async function diffs(path: string, expected: string): Promise<boolean> {
  try {
    const actual = await Deno.readTextFile(path);
    return actual !== expected;
  } catch (_) {
    return true; // missing file counts as stale
  }
}

function lowerFirst(s: string): string {
  return s.length === 0 ? s : s[0].toLowerCase() + s.slice(1);
}

// CLI shim
if (import.meta.main) {
  const mode = Deno.args.includes("--check") ? "check" : "write";
  const result = await generate({
    repoRoot: DEFAULT_REPO_ROOT,
    sourceDir: DEFAULT_SOURCE_DIR,
    swiftOutDir: DEFAULT_SWIFT_OUT,
    tsOutDir: DEFAULT_TS_OUT,
    mode,
  });

  if (mode === "check" && result.stale.length > 0) {
    console.error("Stale generated files:");
    for (const p of result.stale) console.error(`  ${p}`);
    console.error("Run 'make gen' and commit.");
    Deno.exit(1);
  }

  console.log(`Processed: ${result.processed.join(", ") || "(none)"}`);
  if (result.skipped.length > 0) {
    console.log(`Skipped (no marker): ${result.skipped.length} file(s)`);
  }
}
