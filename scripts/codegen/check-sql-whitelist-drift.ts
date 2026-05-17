// scripts/codegen/check-sql-whitelist-drift.ts
//
// CI guard for Swift ↔ SQL whitelist drift.
//
// Background
// ==========
// Several SQL functions like `is_known_vote_type(text)` and
// `is_known_system_event_type(text)` are hand-mirrored from a Swift
// enum on the iOS side (VoteType, SystemEventType, …). Adding a case
// to the Swift enum without shipping a paired migration silently
// breaks decoding for clients on the new build — values inserted by
// the new client trip a soft warn-and-continue on the server, then
// older clients decode the value as unknown.
//
// This script connects to a local Supabase (running in CI via
// `supabase start`), fetches the deployed function body for each
// mirrored SQL function, extracts the array of accepted strings,
// parses the matching Swift enum's known values, and reports any
// difference. Exits non-zero if drift detected.
//
// Configuration
// =============
// The whitelist of mirrored pairs is the constant MIRRORS below.
// Adding a new pair: append an entry pointing at the Swift source +
// the SQL function name. The script auto-detects whether the Swift
// enum is bare-case (e.g. SystemEventType) or raw-value (e.g.
// VoteType with `case fineAppeal = "fine_appeal"`).
//
// Connection
// ==========
// Reads DATABASE_URL from the env. In the edge-tests CI job we
// derive it from `supabase status -o json` and pass it through. For
// local runs, point it at any Supabase instance that has all
// migrations applied (typically `supabase start`).
//
// Usage
// =====
//   deno run -A scripts/codegen/check-sql-whitelist-drift.ts
//
// Exit codes
// ==========
//   0 — no drift
//   1 — drift detected (one or more pairs disagree)
//   2 — runtime error (config bad, DB unreachable, parse failure)

interface MirrorPair {
  /** Path to the Swift source file (relative to repo root). */
  swiftFile: string;
  /** Type name of the Swift enum inside the file. */
  swiftEnum: string;
  /** Name of the SQL function (no schema). */
  sqlFunction: string;
}

const DEFAULT_REPO_ROOT = (() => {
  const here = new URL(".", import.meta.url).pathname;
  return here.replace(/\/scripts\/codegen\/?$/, "");
})();

const MIRRORS: MirrorPair[] = [
  {
    swiftFile: "ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Vote.swift",
    swiftEnum: "VoteType",
    sqlFunction: "is_known_vote_type",
  },
  {
    swiftFile:
      "ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType.swift",
    swiftEnum: "SystemEventType",
    sqlFunction: "is_known_system_event_type",
  },
];

interface DriftReport {
  pair: MirrorPair;
  swiftOnly: string[];
  sqlOnly: string[];
}

async function main(): Promise<number> {
  const dbUrl = Deno.env.get("DATABASE_URL");
  if (!dbUrl) {
    console.error(
      "DATABASE_URL is not set. In CI, derive it from `supabase status -o json` " +
        "and export to $GITHUB_ENV before running this script.",
    );
    return 2;
  }

  const reports: DriftReport[] = [];
  for (const pair of MIRRORS) {
    try {
      const swiftValues = await extractSwiftValues(pair);
      const sqlValues = await extractSqlValues(dbUrl, pair.sqlFunction);

      const swiftOnly = setDiff(swiftValues, sqlValues);
      const sqlOnly = setDiff(sqlValues, swiftValues);

      if (swiftOnly.length > 0 || sqlOnly.length > 0) {
        reports.push({ pair, swiftOnly, sqlOnly });
      }
    } catch (e) {
      console.error(
        `error processing ${pair.swiftEnum} ↔ ${pair.sqlFunction}: ${
          e instanceof Error ? e.message : String(e)
        }`,
      );
      return 2;
    }
  }

  if (reports.length === 0) {
    console.log(
      `OK — ${MIRRORS.length} Swift↔SQL whitelist pair(s) in sync.`,
    );
    return 0;
  }

  console.error("DRIFT DETECTED");
  console.error("==============");
  for (const r of reports) {
    console.error(
      `\n${r.pair.swiftEnum} (${r.pair.swiftFile}) ↔ ${r.pair.sqlFunction}`,
    );
    if (r.swiftOnly.length > 0) {
      console.error(
        `  ▸ in Swift but missing in SQL  (need migration): ${r.swiftOnly.join(", ")}`,
      );
    }
    if (r.sqlOnly.length > 0) {
      console.error(
        `  ▸ in SQL but missing in Swift  (orphan SQL value): ${r.sqlOnly.join(", ")}`,
      );
    }
  }
  console.error(
    "\nFix: ship a migration that re-emits the full whitelist union for " +
      "the function above (per the authoring rule in mig 00211 / 00231). " +
      "Re-run this script to confirm.",
  );
  return 1;
}

/**
 * Extracts the set of accepted string values from a Swift enum source.
 * Pure function: takes the file contents and the target enum name, no
 * filesystem access. The label is used in error messages only.
 *
 * Handles two shapes:
 *   1. Bare-case enum with `case unknown(String)` last:
 *        case eventClosed
 *        case rsvpSubmitted
 *        case unknown(String)
 *      → values are the bare case names ("eventClosed", "rsvpSubmitted").
 *   2. Raw-value enum:
 *        public enum X: String, ... {
 *          case fineAppeal     = "fine_appeal"
 *          case ruleChange     = "rule_change"
 *        }
 *      → values are the raw strings ("fine_appeal", "rule_change").
 */
export function extractSwiftValuesFromText(
  text: string,
  enumName: string,
  label = enumName,
): string[] {
  const lines = text.split(/\r?\n/);

  // Locate the enum header. Tolerate raw-value enums (`: String,`) and
  // protocol-conformance lists.
  const headerRE = new RegExp(
    `^public\\s+enum\\s+${enumName}\\s*(?::[^{]*)?\\{`,
  );
  let headerIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (headerRE.test(lines[i].trim())) {
      headerIdx = i;
      break;
    }
  }
  if (headerIdx < 0) {
    throw new Error(`could not find 'public enum ${enumName}' in ${label}`);
  }

  // Walk body until the closing brace at indent 0. Match both case shapes.
  const RAW_CASE_RE = /^case\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*"([^"]+)"\s*$/;
  const BARE_CASE_RE = /^case\s+([a-z][A-Za-z0-9_]*)\s*$/;
  const UNKNOWN_CASE_RE = /^case\s+unknown\s*\(\s*String\s*\)\s*$/;

  const values: string[] = [];
  let closed = false;

  for (let i = headerIdx + 1; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t === "}") {
      closed = true;
      break;
    }
    if (t === "" || t.startsWith("//") || t.startsWith("///")) continue;
    if (UNKNOWN_CASE_RE.test(t)) continue;

    const rawMatch = t.match(RAW_CASE_RE);
    if (rawMatch) {
      values.push(rawMatch[1]);
      continue;
    }
    const bareMatch = t.match(BARE_CASE_RE);
    if (bareMatch) {
      values.push(bareMatch[1]);
      continue;
    }
    // Ignore unrecognized lines (MARK comments handled above, nested
    // types, methods, etc.). If a real case got skipped the diff will
    // surface it as missing.
  }

  if (!closed) {
    throw new Error(`enum ${enumName} body did not close in ${label}`);
  }
  if (values.length === 0) {
    throw new Error(`enum ${enumName} parsed 0 values from ${label}`);
  }
  return values;
}

async function extractSwiftValues(pair: MirrorPair): Promise<string[]> {
  const path = `${DEFAULT_REPO_ROOT}/${pair.swiftFile}`;
  const text = await Deno.readTextFile(path);
  return extractSwiftValuesFromText(text, pair.swiftEnum, pair.swiftFile);
}

/**
 * Extracts the array literal from a SQL function body of shape:
 *   select <param> = any (array['a','b','c']);
 * Returns the set of string literals inside.
 */
export function extractSqlArrayValues(funcBody: string): string[] {
  const m = funcBody.match(/array\s*\[\s*([\s\S]*?)\s*\]/i);
  if (!m) {
    throw new Error(
      `could not find 'array[...]' literal in function body:\n${funcBody.slice(0, 300)}…`,
    );
  }
  const inside = m[1];
  // Match single-quoted strings, honouring '' as escaped quote (rare here).
  const STR_RE = /'((?:[^']|'')*)'/g;
  const out: string[] = [];
  let sm: RegExpExecArray | null;
  while ((sm = STR_RE.exec(inside)) !== null) {
    out.push(sm[1].replace(/''/g, "'"));
  }
  if (out.length === 0) {
    throw new Error(`array[...] literal had no string elements`);
  }
  return out;
}

// Lazy-import the postgres client only when DB access is actually needed,
// so the parser-only test suite never has to fetch the dependency.
async function extractSqlValues(
  dbUrl: string,
  funcName: string,
): Promise<string[]> {
  const { default: postgres } = await import("npm:postgres@3");
  const sql = postgres(dbUrl, {
    // pg_get_functiondef is read-only; no transactions, prepared, or
    // notice channel needed.
    prepare: false,
    onnotice: () => {},
  });
  try {
    const rows = await sql<{ def: string }[]>`
      select pg_get_functiondef(p.oid) as def
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = ${funcName}
       limit 1
    `;
    if (rows.length === 0 || !rows[0].def) {
      throw new Error(`function public.${funcName}(...) not found in DB`);
    }
    return extractSqlArrayValues(rows[0].def);
  } finally {
    await sql.end({ timeout: 5 });
  }
}

function setDiff(a: string[], b: string[]): string[] {
  const bs = new Set(b);
  return a.filter((x) => !bs.has(x)).sort();
}

if (import.meta.main) {
  const code = await main();
  Deno.exit(code);
}
