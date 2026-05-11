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

const MIGRATION_PATH = new URL(
  "../../migrations/00092_system_events_type_validation.sql",
  import.meta.url,
);

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

Deno.test("00092 SQL whitelist matches SystemEventType codegen values", async () => {
  const sql = await Deno.readTextFile(MIGRATION_PATH);
  const sqlValues = extractWhitelistFromSql(sql).slice().sort();
  const tsValues = (systemEventTypeValues as readonly string[]).slice().sort();
  assertEquals(
    sqlValues,
    tsValues,
    [
      "Whitelist drift detected between SystemEventType (Swift→TS codegen) and",
      "is_known_system_event_type (00092). If you added a new SystemEventType",
      "case, ship a follow-up migration that updates the SQL whitelist —",
      "otherwise the new case lands as NOTICE noise in prod.",
    ].join(" "),
  );
});
