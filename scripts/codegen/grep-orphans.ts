// Orphan-string detector.
//
// Scans target files for camelCase string literals that:
//   (a) appear on the same line as one of the pinned context tokens,
//   (b) are within ORPHAN_PROXIMITY chars of the context token,
//   (c) are not in the catalog (the union of all known enum raw values),
//   (d) are not in the allowlist.
//
// Reports orphans to stdout and exits non-zero if any are found.
// Designed for CI; fast (one pass, no AST).

const ORPHAN_PROXIMITY = 80; // characters
const STRING_LITERAL_RE = /['"]([a-z][A-Za-z0-9]{2,})['"]/g;

export interface FindOrphansOpts {
  catalog: Set<string>;
  targetFiles: string[];
  contextsFile: string;
  allowlistFile: string;
}

export interface Orphan {
  file: string;
  line: number;
  identifier: string;
  context: string;
}

export async function findOrphans(opts: FindOrphansOpts): Promise<Orphan[]> {
  const contexts = await readNonEmptyLines(opts.contextsFile);
  const allowlist = new Set(
    (await readNonEmptyLines(opts.allowlistFile)).map((l) => l.split("#")[0].trim()).filter(
      Boolean,
    ),
  );

  const orphans: Orphan[] = [];

  for (const file of opts.targetFiles) {
    const text = await Deno.readTextFile(file);
    const lines = text.split(/\r?\n/);

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const ctx = contexts.find((c) => line.includes(c));
      if (!ctx) continue;
      const ctxIdx = line.indexOf(ctx);

      STRING_LITERAL_RE.lastIndex = 0;
      let m: RegExpExecArray | null;
      while ((m = STRING_LITERAL_RE.exec(line)) !== null) {
        const litIdx = m.index;
        if (Math.abs(litIdx - ctxIdx) > ORPHAN_PROXIMITY) continue;
        const ident = m[1];
        if (opts.catalog.has(ident) || allowlist.has(ident)) continue;
        orphans.push({ file, line: i + 1, identifier: ident, context: ctx });
      }
    }
  }

  return orphans;
}

async function readNonEmptyLines(path: string): Promise<string[]> {
  const text = await Deno.readTextFile(path);
  return text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith("#"));
}

// CLI shim
if (import.meta.main) {
  const repoRoot = (() => {
    const here = new URL(".", import.meta.url).pathname;
    return here.replace(/\/scripts\/codegen\/?$/, "");
  })();
  const tsTypesDir = `${repoRoot}/supabase/functions/_shared/types`;
  const targetGlobs = [
    `${repoRoot}/supabase/migrations`,
    `${repoRoot}/supabase/functions`,
  ];

  // Build catalog from generated TS files.
  const catalog = new Set<string>();
  try {
    for await (const entry of Deno.readDir(tsTypesDir)) {
      if (!entry.isFile || !entry.name.endsWith(".ts")) continue;
      const content = await Deno.readTextFile(`${tsTypesDir}/${entry.name}`);
      for (const m of content.matchAll(/"([a-z][A-Za-z0-9]+)"/g)) {
        catalog.add(m[1]);
      }
    }
  } catch (_) {
    // _shared/types/ doesn't exist or is empty — catalog stays empty.
  }

  // Walk target dirs for .sql / .ts files (exclude generated TS types).
  const targetFiles: string[] = [];
  for (const dir of targetGlobs) {
    for await (const entry of walk(dir)) {
      if (!entry.isFile) continue;
      if (entry.path.includes("/_shared/types/")) continue;
      // Skip non-live SQL kept for reference (supabase/migrations/_archive,
      // _archive_pre_d21, _rollbacks). They are never deployed forward and
      // only accumulate historical literals.
      if (entry.path.includes("/migrations/_")) continue;
      if (entry.path.endsWith(".sql") || entry.path.endsWith(".ts")) {
        targetFiles.push(entry.path);
      }
    }
  }

  const orphans = await findOrphans({
    catalog,
    targetFiles,
    contextsFile: `${repoRoot}/scripts/codegen/orphan-contexts.txt`,
    allowlistFile: `${repoRoot}/scripts/codegen/orphan-allowlist.txt`,
  });

  if (orphans.length > 0) {
    console.error(`Found ${orphans.length} orphan enum-shaped string literals:`);
    for (const o of orphans) {
      console.error(`  ${o.file}:${o.line}: '${o.identifier}' near '${o.context}'`);
    }
    console.error("");
    console.error("Resolve by either:");
    console.error(
      "  - adding the identifier to the matching Swift enum source, then 'make gen'; or",
    );
    console.error(
      "  - adding it to scripts/codegen/orphan-allowlist.txt with a one-line origin comment.",
    );
    Deno.exit(1);
  }

  console.log(`Scanned ${targetFiles.length} files; no orphan string literals.`);
}

async function* walk(
  root: string,
): AsyncGenerator<{ path: string; isFile: boolean }> {
  try {
    for await (const entry of Deno.readDir(root)) {
      const path = `${root}/${entry.name}`;
      if (entry.isFile) {
        yield { path, isFile: true };
      } else if (entry.isDirectory) {
        yield* walk(path);
      }
    }
  } catch (_) {
    // Skip unreadable dirs silently.
  }
}
