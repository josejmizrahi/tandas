// Verifies the SQL whitelist in migration 00116 (the
// `is_known_vote_type` function body) stays in sync with the iOS
// `VoteType` Swift enum. When the enum grows, this test fails so the
// drift surfaces in CI instead of hiding as silent NOTICE noise in
// prod logs (or worse — Vote rows iOS can't decode, see the
// "decisiones tomadas = 0" symptom that triggered 00116).
//
// Reads both files directly. There's no codegen mirror for VoteType
// (unlike SystemEventType which lives in
// `_shared/types/systemEventType.ts`), so this test is the only
// guard against Swift→SQL drift.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const MIGRATION_PATH = new URL(
  "../../migrations/00116_vote_type_validation.sql",
  import.meta.url,
);
const SWIFT_PATH = new URL(
  "../../../ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Vote.swift",
  import.meta.url,
);

function extractWhitelistFromSql(sql: string): string[] {
  // Same parser shape as the system_event_type sync test — locates the
  // `any (array[ ... ])` block inside the function body and pulls every
  // single-quoted string. Restricted to snake_case identifiers so the
  // RAISE NOTICE / format-string literals don't leak in.
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
  const matches = block.matchAll(/'([a-z][a-z_]*)'/g);
  return Array.from(matches, (m) => m[1]);
}

function extractEnumRawValuesFromSwift(source: string): string[] {
  // Parse VoteType enum body. Captures `case <name> = "<raw>"` lines.
  // We need the raw values (snake_case) since those are what land in
  // the database.
  const enumStart = source.indexOf("public enum VoteType");
  if (enumStart < 0) throw new Error("could not find VoteType enum in Vote.swift");
  const tail = source.slice(enumStart);
  const enumEnd = tail.indexOf("\n}");
  if (enumEnd < 0) throw new Error("could not find VoteType closing brace");
  const body = tail.slice(0, enumEnd);
  const matches = body.matchAll(/case\s+\w+\s*=\s*"([a-z][a-z_]*)"/g);
  return Array.from(matches, (m) => m[1]);
}

Deno.test("00116 SQL whitelist matches iOS VoteType enum raw values", async () => {
  const sql = await Deno.readTextFile(MIGRATION_PATH);
  const swift = await Deno.readTextFile(SWIFT_PATH);

  const sqlValues = extractWhitelistFromSql(sql).slice().sort();
  const swiftValues = extractEnumRawValuesFromSwift(swift).slice().sort();

  assertEquals(
    sqlValues,
    swiftValues,
    [
      "Whitelist drift between iOS VoteType (Swift) and is_known_vote_type",
      "(00116). If you added a new VoteType case, ship a follow-up migration",
      "that updates the SQL whitelist — otherwise iOS can't decode votes the",
      "new case produces and the new vote_type lands as NOTICE noise in prod.",
    ].join(" "),
  );
});
