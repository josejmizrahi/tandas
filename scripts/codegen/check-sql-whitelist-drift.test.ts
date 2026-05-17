// Tests for the Swift / SQL parsers used by check-sql-whitelist-drift.ts.
// DB connectivity is not exercised here — see the e2e CI job for that.

import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  extractSqlArrayValues,
  extractSwiftValuesFromText,
} from "./check-sql-whitelist-drift.ts";

Deno.test("extractSqlArrayValues — single line", () => {
  const body = `
    AS $function$
      select p_x = any (array['a','b','c']);
    $function$
  `;
  assertEquals(extractSqlArrayValues(body), ["a", "b", "c"]);
});

Deno.test("extractSqlArrayValues — multi-line with mixed grouping", () => {
  const body = `
    select p_event_type = any (array[
      'eventClosed', 'eventCreated', 'rsvpDeadlinePassed',
      'rsvpSubmitted', 'rsvpChangedSameDay',
      'fineOfficialized', 'finePaid'
    ]);
  `;
  assertEquals(
    extractSqlArrayValues(body),
    [
      "eventClosed",
      "eventCreated",
      "rsvpDeadlinePassed",
      "rsvpSubmitted",
      "rsvpChangedSameDay",
      "fineOfficialized",
      "finePaid",
    ],
  );
});

Deno.test("extractSqlArrayValues — empty array fails", () => {
  const body = `select p_x = any (array[]);`;
  assertThrows(
    () => extractSqlArrayValues(body),
    Error,
    "no string elements",
  );
});

Deno.test("extractSqlArrayValues — no array literal fails", () => {
  assertThrows(
    () => extractSqlArrayValues("select 1;"),
    Error,
    "could not find",
  );
});

Deno.test("extractSwiftValuesFromText — raw-value enum (VoteType shape)", () => {
  const src = `
import Foundation

public enum FakeVote: String, Codable, Sendable, Hashable, CaseIterable {
    case fineAppeal       = "fine_appeal"
    case ruleChange       = "rule_change"
    case ledgerReview     = "ledger_review"
}
`;
  assertEquals(
    extractSwiftValuesFromText(src, "FakeVote"),
    ["fine_appeal", "rule_change", "ledger_review"],
  );
});

Deno.test("extractSwiftValuesFromText — bare-case enum with unknown(String)", () => {
  const src = `
import Foundation

// @codegen:enum
public enum FakeAtoms: Codable, Sendable, Hashable {
    case eventClosed
    case rsvpSubmitted
    case finePaid
    case unknown(String)
}
`;
  assertEquals(
    extractSwiftValuesFromText(src, "FakeAtoms"),
    ["eventClosed", "rsvpSubmitted", "finePaid"],
  );
});

Deno.test("extractSwiftValuesFromText — comments and MARK lines ignored", () => {
  const src = `
public enum FakeMixed: Codable, Sendable, Hashable {
    // MARK: - Fines
    /// fine officialized
    case fineOfficialized
    /// case foo in a comment should not be picked up
    case fineVoided
    case unknown(String)
}
`;
  assertEquals(
    extractSwiftValuesFromText(src, "FakeMixed"),
    ["fineOfficialized", "fineVoided"],
  );
});

Deno.test("extractSwiftValuesFromText — missing enum throws", () => {
  const src = `public enum Other { case x }`;
  assertThrows(
    () => extractSwiftValuesFromText(src, "DoesNotExist"),
    Error,
    "could not find",
  );
});

Deno.test("extractSwiftValuesFromText — raw values with multiple per line ignored", () => {
  // Real Swift never puts two cases on one line, so a single `case ...`
  // per line is a fair assumption.
  const src = `
public enum Single: String {
    case a = "a1"
    case b = "b1"
}
`;
  assertEquals(extractSwiftValuesFromText(src, "Single"), ["a1", "b1"]);
});
