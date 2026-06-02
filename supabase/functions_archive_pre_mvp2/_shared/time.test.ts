// Unit tests for the test-controllable clock helper.
//
// Run with: deno test --allow-env --allow-net supabase/functions/_shared/time.test.ts

import { assertEquals, assertNotEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { clockOverrideEnabled, getNow } from "./time.ts";
import { _resetLogSink, _setLogSink, type StructuredEntry } from "./log.ts";

function captureLogs(): { entries: StructuredEntry[]; restore: () => void } {
  const entries: StructuredEntry[] = [];
  _setLogSink((e) => entries.push(e));
  return { entries, restore: () => _resetLogSink() };
}

function withEnv<T>(key: string, value: string | undefined, body: () => T): T {
  const prior = Deno.env.get(key);
  if (value === undefined) Deno.env.delete(key);
  else Deno.env.set(key, value);
  try {
    return body();
  } finally {
    if (prior === undefined) Deno.env.delete(key);
    else Deno.env.set(key, prior);
  }
}

Deno.test("getNow() with no request → real now (override never applies)", () => {
  withEnv("ALLOW_CLOCK_OVERRIDE", "true", () => {
    const before = Date.now();
    const t = getNow();
    const after = Date.now();
    // Should be a real timestamp within the call window.
    assertEquals(t.getTime() >= before, true);
    assertEquals(t.getTime() <= after, true);
  });
});

Deno.test("getNow(req) without override flag → real now (header ignored)", () => {
  withEnv("ALLOW_CLOCK_OVERRIDE", undefined, () => {
    const req = new Request("http://localhost/", {
      headers: { "X-Test-Clock": "2030-01-01T00:00:00Z" },
    });
    const t = getNow(req);
    // Real now is 2026-ish, override would be 2030. Confirm we got real.
    assertEquals(t.getFullYear() < 2030, true);
  });
});

Deno.test("getNow(req) with flag + valid header → override applied + warn log", () => {
  const { entries, restore } = captureLogs();
  try {
    withEnv("ALLOW_CLOCK_OVERRIDE", "true", () => {
      const req = new Request("http://localhost/", {
        headers: { "X-Test-Clock": "2030-06-15T12:00:00Z" },
      });
      const t = getNow(req);
      assertEquals(t.toISOString(), "2030-06-15T12:00:00.000Z");

      assertEquals(entries.length, 1);
      assertEquals(entries[0].level, "warn");
      assertEquals(entries[0].code, "time.clock_override_applied");
      assertEquals(entries[0].override_iso, "2030-06-15T12:00:00.000Z");
    });
  } finally {
    restore();
  }
});

Deno.test("getNow(req) with flag + invalid header → falls back to real now + warn log", () => {
  const { entries, restore } = captureLogs();
  try {
    withEnv("ALLOW_CLOCK_OVERRIDE", "true", () => {
      const req = new Request("http://localhost/", {
        headers: { "X-Test-Clock": "not-a-date" },
      });
      const t = getNow(req);
      // Real now, NOT a parsed garbage date.
      assertEquals(t.getFullYear() < 2030, true);
      assertNotEquals(Number.isNaN(t.getTime()), true);

      assertEquals(entries.length, 1);
      assertEquals(entries[0].level, "warn");
      assertEquals(entries[0].code, "time.clock_override_invalid");
      assertEquals(entries[0].header_value, "not-a-date");
    });
  } finally {
    restore();
  }
});

Deno.test("getNow(req) with flag but no header → real now (no log)", () => {
  const { entries, restore } = captureLogs();
  try {
    withEnv("ALLOW_CLOCK_OVERRIDE", "true", () => {
      const req = new Request("http://localhost/");
      const t = getNow(req);
      assertEquals(t.getFullYear() < 2030, true);
      assertEquals(entries.length, 0);
    });
  } finally {
    restore();
  }
});

Deno.test("clockOverrideEnabled() returns true only for exact 'true' env value", () => {
  withEnv("ALLOW_CLOCK_OVERRIDE", "true", () => {
    assertEquals(clockOverrideEnabled(), true);
  });
  withEnv("ALLOW_CLOCK_OVERRIDE", "TRUE", () => {
    assertEquals(clockOverrideEnabled(), false);
  });
  withEnv("ALLOW_CLOCK_OVERRIDE", "1", () => {
    assertEquals(clockOverrideEnabled(), false);
  });
  withEnv("ALLOW_CLOCK_OVERRIDE", undefined, () => {
    assertEquals(clockOverrideEnabled(), false);
  });
});
