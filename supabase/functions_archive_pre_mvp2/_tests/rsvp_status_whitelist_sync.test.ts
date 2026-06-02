// Verifies the SQL whitelist in `is_known_rsvp_status` stays in sync
// with the iOS `RSVPStatus` Swift enum. Same pattern as the
// system_event / vote_type sync tests — text-parses both sources so
// no codegen mirror is required.
//
// Auto-discovers the latest migration that defines the function so
// follow-up migrations updating the whitelist (Phase 2 adding
// `tentative`, etc.) don't break the test.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const MIGRATIONS_DIR = new URL("../../migrations/", import.meta.url);
const SWIFT_PATH = new URL(
  "../../../ios/Packages/RuulCore/Sources/RuulCore/Events/RSVPStatus.swift",
  import.meta.url,
);

async function readLatestRsvpStatusMigration(): Promise<string> {
  const dir = await Deno.readDir(MIGRATIONS_DIR);
  const candidates: string[] = [];
  for await (const entry of dir) {
    if (!entry.isFile || !entry.name.endsWith(".sql")) continue;
    if (entry.name.includes("rollback")) continue;
    const body = await Deno.readTextFile(new URL(entry.name, MIGRATIONS_DIR));
    if (body.includes("create or replace function public.is_known_rsvp_status")) {
      candidates.push(entry.name);
    }
  }
  if (candidates.length === 0) {
    throw new Error("no migration defines is_known_rsvp_status");
  }
  candidates.sort();
  const latest = candidates[candidates.length - 1];
  return Deno.readTextFile(new URL(latest, MIGRATIONS_DIR));
}

function extractWhitelistFromSql(sql: string): string[] {
  const start = sql.indexOf("any (array[");
  if (start < 0) throw new Error("could not locate 'any (array[' in migration body");
  const tail = sql.slice(start);
  const end = tail.indexOf("])");
  if (end < 0) throw new Error("could not locate closing '])'");
  const block = tail.slice(0, end);
  const matches = block.matchAll(/'([a-z][a-z_]*)'/g);
  return Array.from(matches, (m) => m[1]);
}

function extractEnumCasesFromSwift(source: string): string[] {
  // RSVPStatus is a String-rawValue enum with bare `case foo` (no `=`).
  // Bare-case cases use the case name as the raw value (lowercase
  // identifier). Parser handles both `case foo` and `case foo = "bar"`.
  const enumStart = source.indexOf("public enum RSVPStatus");
  if (enumStart < 0) throw new Error("could not find RSVPStatus enum");
  const tail = source.slice(enumStart);
  const enumEnd = tail.indexOf("\n}");
  if (enumEnd < 0) throw new Error("could not find RSVPStatus closing brace");
  const body = tail.slice(0, enumEnd);
  const out: string[] = [];
  for (const line of body.split("\n")) {
    const eq = line.match(/case\s+\w+\s*=\s*"([a-z][a-z_]*)"/);
    if (eq) { out.push(eq[1]); continue; }
    const bare = line.match(/^\s*case\s+([a-z][a-zA-Z_]*)\s*$/);
    if (bare) out.push(bare[1]);
  }
  return out;
}

Deno.test("latest SQL whitelist matches iOS RSVPStatus enum cases", async () => {
  const sql = await readLatestRsvpStatusMigration();
  const swift = await Deno.readTextFile(SWIFT_PATH);

  const sqlValues = extractWhitelistFromSql(sql).slice().sort();
  const swiftValues = extractEnumCasesFromSwift(swift).slice().sort();

  assertEquals(
    sqlValues,
    swiftValues,
    [
      "Whitelist drift between iOS RSVPStatus (Swift) and",
      "is_known_rsvp_status (00118+). If you added a new case, ship a",
      "follow-up migration that redefines the function — the CHECK",
      "constraint event_attendance_rsvp_status_check would otherwise",
      "reject the INSERT.",
    ].join(" "),
  );
});
