// Sync tests for the 6 secondary `is_known_*` whitelist functions
// introduced in 00121 that have an iOS Swift enum mirror:
//
//   events.status                    ↔ EventStatus
//   fines.status                     ↔ FineStatus
//   groups.category                  ↔ GroupCategory
//   otp_codes.channel                ↔ OTPChannel
//   rule_shapes.kind                 ↔ RuleShape.Kind
//   event_attendance.check_in_method ↔ CheckInMethod
//
// Same shape as the system_event/vote_type/rsvp_status/policy_type
// sync tests: parse the SQL whitelist out of the latest migration
// defining the function, parse the Swift enum cases (handling both
// bare-case and explicit-rawValue forms), assert they match.
//
// `group_members.role` and `notification_tokens.platform` have no
// iOS enum mirror today; their canonical lives in SQL and they're
// excluded here intentionally.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const MIGRATIONS_DIR = new URL("../../migrations/", import.meta.url);
const SWIFT_ROOT = new URL(
  "../../../ios/Packages/RuulCore/Sources/RuulCore/",
  import.meta.url,
);

async function readLatestMigration(functionName: string): Promise<string> {
  const candidates: string[] = [];
  for await (const entry of Deno.readDir(MIGRATIONS_DIR)) {
    if (!entry.isFile || !entry.name.endsWith(".sql")) continue;
    if (entry.name.includes("rollback")) continue;
    const body = await Deno.readTextFile(new URL(entry.name, MIGRATIONS_DIR));
    if (body.includes(`create or replace function public.${functionName}`)) {
      candidates.push(entry.name);
    }
  }
  if (candidates.length === 0) {
    throw new Error(`no migration defines ${functionName}`);
  }
  candidates.sort();
  return Deno.readTextFile(
    new URL(candidates[candidates.length - 1], MIGRATIONS_DIR),
  );
}

/// Extracts the bracketed-array whitelist that follows the named
/// function's signature. Multiple `is_known_*` functions can coexist
/// in the same migration; the anchor argument scopes the search.
function extractWhitelist(sql: string, functionName: string): string[] {
  const fnStart = sql.indexOf(
    `create or replace function public.${functionName}`,
  );
  if (fnStart < 0) throw new Error(`could not find ${functionName}`);
  const tail = sql.slice(fnStart);
  const arrStart = tail.indexOf("any (array[");
  if (arrStart < 0) throw new Error(`no 'any (array[' after ${functionName}`);
  const fromArr = tail.slice(arrStart);
  const arrEnd = fromArr.indexOf("])");
  if (arrEnd < 0) throw new Error("missing closing '])'");
  const block = fromArr.slice(0, arrEnd);
  // The whitelist values cover snake_case identifiers (most enums) plus
  // camelCase ones (GroupCategory uses bare cases that Swift exposes as
  // camelCase rawValues). Restrict to identifier-like strings so
  // RAISE NOTICE format strings don't leak.
  const matches = block.matchAll(/'([a-zA-Z][a-zA-Z_]*)'/g);
  return Array.from(matches, (m) => m[1]);
}

/// Pulls every case raw-value from a Swift enum body. Handles:
///   `case foo`                          → "foo"   (default rawValue = case name)
///   `case foo = "bar_baz"`              → "bar_baz"
///   `case whatsapp, sms`                → "whatsapp", "sms"  (comma list)
///   `public enum X { case y, z }`       → single-line (body has no newlines)
///
/// Locates the enum body via brace-depth tracking instead of a `\n}`
/// heuristic so it's robust to indented closing braces (nested enums
/// inside a struct) and single-line enum definitions.
function extractEnumCases(swift: string, enumName: string): string[] {
  const start = swift.indexOf(`public enum ${enumName}`);
  if (start < 0) throw new Error(`could not find ${enumName} enum`);
  const openIdx = swift.indexOf("{", start);
  if (openIdx < 0) throw new Error(`no '{' after enum ${enumName}`);

  let depth = 1;
  let i = openIdx + 1;
  while (i < swift.length && depth > 0) {
    const ch = swift[i];
    if (ch === "{") depth++;
    else if (ch === "}") depth--;
    if (depth === 0) break;
    i++;
  }
  if (depth !== 0) throw new Error(`unbalanced braces in enum ${enumName}`);
  const body = swift.slice(openIdx + 1, i);

  const out: string[] = [];
  for (const rawLine of body.split("\n")) {
    // Drop trailing comments before parsing (e.g. `case foo  // note`).
    const line = rawLine.replace(/\/\/.*$/, "");

    // Comma-list form: `case foo, bar, baz`. We treat it as bare-case
    // for every entry (rawValue defaults to the case name).
    const list = line.match(/^\s*case\s+([a-zA-Z][a-zA-Z_]*(\s*,\s*[a-zA-Z][a-zA-Z_]*)+)\s*$/);
    if (list) {
      for (const name of list[1].split(",")) out.push(name.trim());
      continue;
    }

    // Explicit rawValue form (snake_case or camelCase) — `case foo = "bar"`.
    const eq = line.match(/case\s+\w+\s*=\s*"([a-zA-Z][a-zA-Z_]*)"/);
    if (eq) { out.push(eq[1]); continue; }

    // Bare-case form — `case foo`.
    const bare = line.match(/^\s*case\s+([a-zA-Z][a-zA-Z_]*)\s*$/);
    if (bare) out.push(bare[1]);
  }
  return out;
}

async function assertSync(
  sqlFn: string,
  swiftFile: string,
  swiftEnum: string,
) {
  const sql = await readLatestMigration(sqlFn);
  const swift = await Deno.readTextFile(new URL(swiftFile, SWIFT_ROOT));
  const sqlValues = extractWhitelist(sql, sqlFn).slice().sort();
  const swiftValues = extractEnumCases(swift, swiftEnum).slice().sort();
  assertEquals(
    sqlValues,
    swiftValues,
    [
      `Whitelist drift between iOS ${swiftEnum} and ${sqlFn}.`,
      "Ship a follow-up migration redefining the function — the CHECK",
      "constraint backing this column would otherwise reject the INSERT.",
    ].join(" "),
  );
}

Deno.test("latest is_known_event_status matches iOS EventStatus", () =>
  assertSync(
    "is_known_event_status",
    "Events/EventStatus.swift",
    "EventStatus",
  ));

Deno.test("latest is_known_fine_status matches iOS FineStatus", () =>
  assertSync(
    "is_known_fine_status",
    "PlatformModels/Fine.swift",
    "FineStatus",
  ));

Deno.test("latest is_known_group_category matches iOS GroupCategory", () =>
  assertSync(
    "is_known_group_category",
    "PlatformModels/GroupCategory.swift",
    "GroupCategory",
  ));

Deno.test("latest is_known_otp_channel matches iOS OTPChannel", () =>
  assertSync(
    "is_known_otp_channel",
    "Services/OTP/OTPService.swift",
    "OTPChannel",
  ));

Deno.test("latest is_known_check_in_method matches iOS CheckInMethod", () =>
  assertSync(
    "is_known_check_in_method",
    "Events/CheckInMethod.swift",
    "CheckInMethod",
  ));

// RuleShape.Kind is nested inside `public struct RuleShape`; the parser
// supports nested enums because it locates by `public enum Kind` —
// uniqueness within the file is enough.
Deno.test("latest is_known_rule_shape_kind matches iOS RuleShape.Kind", () =>
  assertSync(
    "is_known_rule_shape_kind",
    "PlatformModels/RuleShape.swift",
    "Kind",
  ));
