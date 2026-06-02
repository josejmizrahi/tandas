// Pure helpers that the `buildContext` function in process-system-events
// composes into a full `RuleContext`. Extracted so the polymorphic
// resource-resolution + event-attendance derivation logic can be unit
// tested without a live Supabase connection.
//
// The shape decisions baked in here (when to use `events_view` vs the
// `resources` row directly, how to derive `minutes_late`) are the
// audit-critical bits — leaving them inline inside `buildContext` left
// them covered only by e2e tests that require a real database.

import type { RSVPLike, CheckInLike, ResourceLike } from "./ruleEngine.ts";
import type { UUID } from "./platformTypes.ts";

/**
 * Polymorphic resource row from `public.resources`. Mirrors the columns
 * the buildContext select reads. Loosely typed because Supabase responses
 * are `unknown` in strict TS mode.
 */
export interface ResourcesRow {
  id: UUID;
  group_id: UUID;
  resource_type: string;
  status: string;
  metadata: Record<string, unknown> | null;
  series_id: UUID | null;
}

/**
 * Event-shaped projection from `public.events_view`. Sparser than the
 * legacy `events` table — only the fields the engine needs are documented
 * here.
 */
export interface EventsViewRow {
  resource_id: UUID;
  group_id: UUID;
  resource_type: string;
  status: string;
  metadata: Record<string, unknown>;
}

/**
 * Compose the polymorphic `ResourceLike` the engine consumes from the
 * universal `resources` row plus an optional event-shaped projection.
 *
 * Decision tree:
 *   - resourcesRow is null → no resource resolvable (engine returns no targets).
 *   - resourceType === 'event' → require eventsViewRow (events still
 *       live in the legacy table with richer fields like host_id/
 *       starts_at; events_view is the projection that exposes them).
 *       Falls back to null when the events_view query missed (an event
 *       resource without an `events` row would be a data-integrity bug).
 *   - any other resource_type → build straight from the resources row.
 *       Slots/funds/assets carry their domain data in `resources.metadata`
 *       and don't need the events_view detour.
 *
 * The `series_id` always comes from the resources row — events_view
 * doesn't surface it, but the dual-write trigger keeps resources.series_id
 * authoritative.
 */
export function composeResourceLike(
  resourcesRow: ResourcesRow | null,
  eventsViewRow: EventsViewRow | null,
): ResourceLike | null {
  if (!resourcesRow) return null;

  if (resourcesRow.resource_type === "event") {
    if (!eventsViewRow) return null;
    return {
      id: eventsViewRow.resource_id,
      group_id: eventsViewRow.group_id,
      resource_type: eventsViewRow.resource_type,
      status: eventsViewRow.status,
      metadata: eventsViewRow.metadata,
      series_id: resourcesRow.series_id,
    };
  }

  return {
    id: resourcesRow.id,
    group_id: resourcesRow.group_id,
    resource_type: resourcesRow.resource_type,
    status: resourcesRow.status,
    metadata: resourcesRow.metadata ?? {},
    series_id: resourcesRow.series_id,
  };
}

/**
 * Raw event_attendance row shape. Each row holds both the RSVP state and
 * (optionally) the check-in timestamp.
 */
export interface EventAttendanceRow {
  user_id: UUID;
  rsvp_status: RSVPLike["status"];
  rsvp_at: string | null;
  cancelled_same_day: boolean | null;
  arrived_at: string | null;
}

/**
 * Derive the engine's RSVP array from raw event_attendance rows. Every
 * row produces one RSVP entry regardless of whether the user has
 * arrived yet — the rsvpChangedSameDay / responseStatusIs evaluators
 * read from this list.
 */
export function mapAttendanceToRsvps(attendance: EventAttendanceRow[]): RSVPLike[] {
  return attendance.map((a) => ({
    member_user_id: a.user_id,
    status: a.rsvp_status,
    rsvp_at: a.rsvp_at,
    cancelled_same_day: a.cancelled_same_day ?? false,
  }));
}

/**
 * Derive the engine's check-in array, including the `minutes_late`
 * computation relative to the event's `starts_at`. Rows without an
 * `arrived_at` value are dropped (no check-in = no row). When `startsAt`
 * is unknown, `minutes_late` collapses to 0 so the threshold conditions
 * never trip — better than a NaN propagating into the engine.
 */
export function mapAttendanceToCheckIns(
  attendance: EventAttendanceRow[],
  startsAt: string | null,
): CheckInLike[] {
  const startsAtMs = startsAt ? new Date(startsAt).getTime() : null;
  return attendance
    .filter((a): a is EventAttendanceRow & { arrived_at: string } => a.arrived_at != null)
    .map((a) => ({
      member_user_id: a.user_id,
      arrived_at: a.arrived_at,
      minutes_late:
        startsAtMs != null && !Number.isNaN(startsAtMs)
          ? Math.round((new Date(a.arrived_at).getTime() - startsAtMs) / 60_000)
          : 0,
    }));
}
