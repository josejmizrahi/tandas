// Verifies the SQL whitelist in migration 00092 (the
// `is_known_system_event_type` function body) stays in sync with the
// codegen-produced `SystemEventType` union. When the Swift enum grows,
// `make gen` regenerates `systemEventType.ts`; without a paired
// migration this test fails so the drift surfaces in CI instead of
// hiding as silent NOTICE noise in prod logs.
//
// Reads the SQL string literals out of the migration file itself
// rather than connecting to the database — no infra required.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { systemEventTypeValues } from "../_shared/types/systemEventType.ts";

const MIGRATIONS_DIR = new URL("../../migrations/", import.meta.url);

/// Finds the most recent migration that defines
/// `is_known_system_event_type` so the test stays correct when a future
/// migration extends the whitelist (e.g. 00117 added pendingChangeApplied
/// without touching 00092's body). Returns the migration body as text;
/// if no migration defines the function, throws.
async function readLatestWhitelistMigration(): Promise<string> {
  const dir = await Deno.readDir(MIGRATIONS_DIR);
  const candidates: string[] = [];
  for await (const entry of dir) {
    if (!entry.isFile || !entry.name.endsWith(".sql")) continue;
    if (entry.name.includes("rollback")) continue;
    const body = await Deno.readTextFile(new URL(entry.name, MIGRATIONS_DIR));
    if (body.includes("create or replace function public.is_known_system_event_type")) {
      candidates.push(entry.name);
    }
  }
  if (candidates.length === 0) {
    throw new Error("no migration defines is_known_system_event_type");
  }
  // Lexicographic sort works because migration filenames are zero-padded.
  candidates.sort();
  const latest = candidates[candidates.length - 1];
  return Deno.readTextFile(new URL(latest, MIGRATIONS_DIR));
}

function extractWhitelistFromSql(sql: string): string[] {
  // The function body is `select p_event_type = any (array[ '...', '...' ])`.
  // Capture the bracketed list and split on quoted entries — more robust
  // than a single regex against multi-line content.
  const start = sql.indexOf("any (array[");
  if (start < 0) {
    throw new Error("could not locate 'any (array[' in migration body");
  }
  const tail = sql.slice(start);
  const end = tail.indexOf("])");
  if (end < 0) {
    throw new Error("could not locate closing '])' in migration body");
  }
  const block = tail.slice(0, end);
  const matches = block.matchAll(/'([a-zA-Z][a-zA-Z0-9]*)'/g);
  return Array.from(matches, (m) => m[1]);
}

Deno.test("latest SQL whitelist matches SystemEventType codegen values", async () => {
  const sql = await readLatestWhitelistMigration();
  const sqlValues = extractWhitelistFromSql(sql).slice().sort();
  const tsValues = (systemEventTypeValues as readonly string[]).slice().sort();
  assertEquals(
    sqlValues,
    tsValues,
    [
      "Whitelist drift detected between SystemEventType (Swift→TS codegen) and",
      "is_known_system_event_type. If you added a new SystemEventType case,",
      "ship a follow-up migration that redefines the function with the new",
      "value — the CHECK constraint (00095) would otherwise reject the INSERT.",
    ].join(" "),
  );
});
