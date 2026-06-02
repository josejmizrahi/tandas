// Verifies the SQL whitelist in `is_known_policy_type` stays in sync
// with the iOS `PolicyType` Swift enum. Same auto-discovery pattern as
// the rsvp_status / vote_type / system_event sync tests.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const MIGRATIONS_DIR = new URL("../../migrations/", import.meta.url);
const SWIFT_PATH = new URL(
  "../../../ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/GroupPolicy.swift",
  import.meta.url,
);

async function readLatestPolicyTypeMigration(): Promise<string> {
  const dir = await Deno.readDir(MIGRATIONS_DIR);
  const candidates: string[] = [];
  for await (const entry of dir) {
    if (!entry.isFile || !entry.name.endsWith(".sql")) continue;
    if (entry.name.includes("rollback")) continue;
    const body = await Deno.readTextFile(new URL(entry.name, MIGRATIONS_DIR));
    if (body.includes("create or replace function public.is_known_policy_type")) {
      candidates.push(entry.name);
    }
  }
  if (candidates.length === 0) {
    throw new Error("no migration defines is_known_policy_type");
  }
  candidates.sort();
  return Deno.readTextFile(new URL(candidates[candidates.length - 1], MIGRATIONS_DIR));
}

function extractWhitelistFromSql(sql: string): string[] {
  // The migration defines two `is_known_*` functions back to back. We
  // only want the policy_type one — locate it by anchoring the search
  // at the policy_type function signature.
  const fnStart = sql.indexOf(
    "create or replace function public.is_known_policy_type",
  );
  if (fnStart < 0) throw new Error("could not find is_known_policy_type");
  const tail = sql.slice(fnStart);
  const arrStart = tail.indexOf("any (array[");
  if (arrStart < 0) throw new Error("could not locate 'any (array[' in body");
  const fromArr = tail.slice(arrStart);
  const arrEnd = fromArr.indexOf("])");
  if (arrEnd < 0) throw new Error("could not locate closing '])'");
  const block = fromArr.slice(0, arrEnd);
  const matches = block.matchAll(/'([a-z][a-z_]*)'/g);
  return Array.from(matches, (m) => m[1]);
}

function extractEnumRawValuesFromSwift(source: string): string[] {
  // PolicyType has a mix of bare-case (where the rawValue IS the case
  // name in camelCase) and explicit "snake_case" rawValues. For the
  // bare cases, the rawValue equals the case name literally (e.g.
  // `case direct` → "direct"). We expand both shapes.
  const enumStart = source.indexOf("public enum PolicyType");
  if (enumStart < 0) throw new Error("could not find PolicyType enum");
  const tail = source.slice(enumStart);
  const enumEnd = tail.indexOf("\n}");
  if (enumEnd < 0) throw new Error("could not find PolicyType closing brace");
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

Deno.test("latest SQL whitelist matches iOS PolicyType enum", async () => {
  const sql = await readLatestPolicyTypeMigration();
  const swift = await Deno.readTextFile(SWIFT_PATH);

  const sqlValues = extractWhitelistFromSql(sql).slice().sort();
  const swiftValues = extractEnumRawValuesFromSwift(swift).slice().sort();

  assertEquals(
    sqlValues,
    swiftValues,
    [
      "Whitelist drift between iOS PolicyType (Swift) and",
      "is_known_policy_type (00119+). If you added a new case, ship a",
      "follow-up migration that redefines the function — the CHECK",
      "constraint group_policies_policy_type_check would otherwise",
      "reject the INSERT.",
    ].join(" "),
  );
});
