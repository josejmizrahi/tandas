// Unit tests for the pure helpers buildContext composes. No Supabase
// dependency — the helpers take already-fetched row data and produce
// the shapes the rule engine consumes.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  composeResourceLike,
  mapAttendanceToCheckIns,
  mapAttendanceToRsvps,
  type EventAttendanceRow,
  type EventsViewRow,
  type ResourcesRow,
} from "./ruleContext.ts";

const resourceId = "r0000000-0000-0000-0000-000000000001";
const groupId    = "g0000000-0000-0000-0000-000000000001";
const seriesId   = "s0000000-0000-0000-0000-000000000001";

function eventResourcesRow(over: Partial<ResourcesRow> = {}): ResourcesRow {
  return {
    id: resourceId,
    group_id: groupId,
    resource_type: "event",
    status: "scheduled",
    metadata: {},
    series_id: null,
    ...over,
  };
}

function eventsView(over: Partial<EventsViewRow> = {}): EventsViewRow {
  return {
    resource_id: resourceId,
    group_id: groupId,
    resource_type: "event",
    status: "scheduled",
    metadata: { starts_at: "2026-05-04T20:30:00Z", host_id: "u-1" },
    ...over,
  };
}

// =============================================================================
// composeResourceLike
// =============================================================================

Deno.test("composeResourceLike returns null when resources row missing", () => {
  const result = composeResourceLike(null, eventsView());
  assertEquals(result, null);
});

Deno.test("composeResourceLike events read from events_view (richer projection)", () => {
  const result = composeResourceLike(
    eventResourcesRow({ series_id: seriesId, metadata: { stale: "ignored" } }),
    eventsView({ metadata: { starts_at: "2026-05-04T20:30:00Z", host_id: "u-1" } }),
  );
  // events_view metadata wins (it carries host_id/starts_at); series_id
  // comes from the resources row because events_view doesn't expose it.
  assertEquals(result?.metadata, { starts_at: "2026-05-04T20:30:00Z", host_id: "u-1" });
  assertEquals(result?.series_id, seriesId);
  assertEquals(result?.resource_type, "event");
});

Deno.test("composeResourceLike event returns null when events_view row missing", () => {
  // Data-integrity bug case: resources row says event, but the events
  // projection has nothing. Returning null is safer than fabricating a
  // resource without the legacy fields the engine's event triggers need.
  const result = composeResourceLike(eventResourcesRow(), null);
  assertEquals(result, null);
});

Deno.test("composeResourceLike slot reads straight from resources row", () => {
  const row: ResourcesRow = {
    id: resourceId,
    group_id: groupId,
    resource_type: "slot",
    status: "open",
    metadata: { capacity: 4, starts_at: "2026-05-04T20:30:00Z" },
    series_id: seriesId,
  };
  const result = composeResourceLike(row, null);
  assertEquals(result, {
    id: resourceId,
    group_id: groupId,
    resource_type: "slot",
    status: "open",
    metadata: { capacity: 4, starts_at: "2026-05-04T20:30:00Z" },
    series_id: seriesId,
  });
});

Deno.test("composeResourceLike non-event ignores any provided events_view row", () => {
  // A stray events_view row (e.g. a stale dual-write) shouldn't override
  // the polymorphic resources row for a fund.
  const row: ResourcesRow = {
    id: resourceId,
    group_id: groupId,
    resource_type: "fund",
    status: "active",
    metadata: { balance_cents: 50_000 },
    series_id: null,
  };
  const result = composeResourceLike(row, eventsView());
  assertEquals(result?.resource_type, "fund");
  assertEquals(result?.metadata, { balance_cents: 50_000 });
});

Deno.test("composeResourceLike fallback when non-event metadata is null", () => {
  const row: ResourcesRow = {
    id: resourceId,
    group_id: groupId,
    resource_type: "asset",
    status: "active",
    metadata: null,
    series_id: null,
  };
  const result = composeResourceLike(row, null);
  assertEquals(result?.metadata, {});
});

// =============================================================================
// mapAttendanceToRsvps
// =============================================================================

Deno.test("mapAttendanceToRsvps emits one RSVP per attendance row", () => {
  const rows: EventAttendanceRow[] = [
    { user_id: "u-a", rsvp_status: "going",    rsvp_at: "2026-05-01T00:00:00Z", cancelled_same_day: false, arrived_at: null },
    { user_id: "u-b", rsvp_status: "declined", rsvp_at: null,                    cancelled_same_day: true,  arrived_at: null },
  ];
  const result = mapAttendanceToRsvps(rows);
  assertEquals(result.length, 2);
  assertEquals(result[0].member_user_id, "u-a");
  assertEquals(result[0].cancelled_same_day, false);
  assertEquals(result[1].cancelled_same_day, true);
});

Deno.test("mapAttendanceToRsvps coalesces null cancelled_same_day to false", () => {
  const rows: EventAttendanceRow[] = [
    {
      user_id: "u-c",
      rsvp_status: "going",
      rsvp_at: null,
      cancelled_same_day: null,
      arrived_at: null,
    },
  ];
  const result = mapAttendanceToRsvps(rows);
  assertEquals(result[0].cancelled_same_day, false);
});

// =============================================================================
// mapAttendanceToCheckIns
// =============================================================================

Deno.test("mapAttendanceToCheckIns drops rows without arrived_at", () => {
  const rows: EventAttendanceRow[] = [
    { user_id: "u-a", rsvp_status: "going",    rsvp_at: null, cancelled_same_day: false, arrived_at: null },
    { user_id: "u-b", rsvp_status: "going",    rsvp_at: null, cancelled_same_day: false, arrived_at: "2026-05-04T20:35:00Z" },
  ];
  const result = mapAttendanceToCheckIns(rows, "2026-05-04T20:30:00Z");
  assertEquals(result.length, 1);
  assertEquals(result[0].member_user_id, "u-b");
});

Deno.test("mapAttendanceToCheckIns computes minutes_late from starts_at", () => {
  const rows: EventAttendanceRow[] = [
    {
      user_id: "u-a",
      rsvp_status: "going",
      rsvp_at: null,
      cancelled_same_day: false,
      arrived_at: "2026-05-04T20:45:00Z",
    },
  ];
  const result = mapAttendanceToCheckIns(rows, "2026-05-04T20:30:00Z");
  assertEquals(result[0].minutes_late, 15);
});

Deno.test("mapAttendanceToCheckIns minutes_late is negative when early", () => {
  const rows: EventAttendanceRow[] = [
    {
      user_id: "u-a",
      rsvp_status: "going",
      rsvp_at: null,
      cancelled_same_day: false,
      arrived_at: "2026-05-04T20:20:00Z",
    },
  ];
  const result = mapAttendanceToCheckIns(rows, "2026-05-04T20:30:00Z");
  assertEquals(result[0].minutes_late, -10);
});

Deno.test("mapAttendanceToCheckIns coalesces minutes_late to 0 when starts_at missing", () => {
  const rows: EventAttendanceRow[] = [
    {
      user_id: "u-a",
      rsvp_status: "going",
      rsvp_at: null,
      cancelled_same_day: false,
      arrived_at: "2026-05-04T20:45:00Z",
    },
  ];
  const result = mapAttendanceToCheckIns(rows, null);
  // Better than NaN propagating into the engine's threshold comparisons.
  assertEquals(result[0].minutes_late, 0);
});
