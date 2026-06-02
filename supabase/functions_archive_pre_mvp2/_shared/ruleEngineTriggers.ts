// Trigger evaluators — split out from ruleEngine.ts for readability
// (mig governance-review item #2). Same registry pattern as
// ruleEngineConditions / ruleEngineConsequences: a
// Record<SystemEventType, Evaluator> map keyed by trigger event type.
//
// Adding a new trigger: implement the TriggerEvaluator function,
// register it in TRIGGERS keyed by the matching SystemEventType, drop
// the case from TRIGGER_PHASE in ruleEngine.ts if it was previously
// reserved for a future phase, and make sure the iOS Swift enum mirror
// has a matching case (the codegen drift check in CI will catch it
// otherwise).

import type {
  Rule,
  RuleTarget,
  SystemEvent,
  SystemEventType,
  UUID,
} from "./platformTypes.ts";
import type { RuleContext } from "./ruleEngine.ts";

export type TriggerEvaluator = (
  event: SystemEvent,
  rule: Rule,
  context: RuleContext,
) => Promise<RuleTarget[]>;

export const TRIGGERS: Partial<Record<SystemEventType, TriggerEvaluator>> = {
  // (V1) Each member of the group is a candidate for fines (no-show, didn't
  // RSVP, etc.). Returns one target per member with their RSVP/check-in.
  eventClosed: async (event, _rule, context) => {
    if (!event.resource_id) return [];
    return context.members
      .filter((m) => m.active)
      .map((m) => ({
        member_id: m.id,
        resource_id: event.resource_id,
        context: {
          user_id: m.user_id,
          rsvp: context.rsvps.find((r) => r.member_user_id === m.user_id) ?? null,
          check_in: context.checkIns.find((c) => c.member_user_id === m.user_id) ?? null,
          event_starts_at: context.resource?.metadata?.starts_at ?? null,
        },
      }));
  },

  // (mig 00203+00209, spec §8+§19) Cancellation is a distinct trigger from
  // close: the rule engine evaluator MUST NOT enumerate "no-show fines" on
  // cancellation (you can't no-show a cancelled event). What CAN fire:
  //   - notification consequences ("avísale a todos los que dijeron 'going'")
  //   - cancellation-fee rules ("if cancelled <24h before, charge host")
  // We enumerate going-RSVP members + the host; conditions decide who really fires.
  eventCancelled: async (event, _rule, context) => {
    if (!event.resource_id) return [];
    const hostUserId = context.resource?.metadata?.host_id as UUID | undefined;
    const startsAt = (context.resource?.metadata?.starts_at as string | undefined)
      ?? (event.payload?.starts_at as string | undefined)
      ?? null;
    return context.members
      .filter((m) => m.active)
      .map((m) => ({
        member_id: m.id,
        resource_id: event.resource_id,
        context: {
          user_id: m.user_id,
          rsvp: context.rsvps.find((r) => r.member_user_id === m.user_id) ?? null,
          is_host: hostUserId === m.user_id,
          event_starts_at: startsAt,
          cancellation_reason: event.payload?.reason ?? null,
          cancelled_by_user: event.payload?.cancelled_by ?? null,
          cancelled_at: event.occurred_at,
        },
      }));
  },

  // (mig 00208, spec §8) Event just started (cron-emitted when starts_at
  // elapses). Same target shape as eventClosed but pre-end: conditions can
  // ask "who hasn't checked in" or "who said going but didn't arrive yet"
  // for nudge / late-fee rule shapes.
  eventStarted: async (event, _rule, context) => {
    if (!event.resource_id) return [];
    return context.members
      .filter((m) => m.active)
      .map((m) => ({
        member_id: m.id,
        resource_id: event.resource_id,
        context: {
          user_id: m.user_id,
          rsvp: context.rsvps.find((r) => r.member_user_id === m.user_id) ?? null,
          check_in: context.checkIns.find((c) => c.member_user_id === m.user_id) ?? null,
          event_starts_at: context.resource?.metadata?.starts_at
            ?? event.payload?.starts_at
            ?? null,
          started_at: event.occurred_at,
        },
      }));
  },

  // (mig 00210, spec §8) Event metadata mutated (location, time, host,
  // description). Target = each member that confirmed 'going' so notification
  // rules can react ("X cambió la hora — avísale a los que ya dijeron sí").
  // The `changed_keys` payload lets conditions narrow which kinds of edits
  // trigger which rules.
  eventUpdated: async (event, _rule, context) => {
    if (!event.resource_id) return [];
    return context.members
      .filter((m) => m.active)
      .map((m) => ({
        member_id: m.id,
        resource_id: event.resource_id,
        context: {
          user_id: m.user_id,
          rsvp: context.rsvps.find((r) => r.member_user_id === m.user_id) ?? null,
          changed_keys: event.payload?.changed_keys ?? [],
          changed_by_user: event.payload?.changed_by ?? null,
          title_changed: event.payload?.title_changed ?? false,
        },
      }));
  },

  // (V1) RSVP deadline passed. Mirrors eventClosed in shape — one target
  // per active member with their RSVP — but fires BEFORE the event so
  // pre-event rules ("no confirmó a tiempo → warning/fine") can run while
  // there's still time for a member to respond. emit-deadline-events
  // emits one row per event (member_id=null, payload carries the
  // rsvp_deadline + starts_at), so the trigger enumerates members like
  // eventClosed does. Conditions (e.g. responseStatusIs("pending"))
  // narrow which targets actually fire.
  rsvpDeadlinePassed: async (event, _rule, context) => {
    if (!event.resource_id) return [];
    return context.members
      .filter((m) => m.active)
      .map((m) => ({
        member_id: m.id,
        resource_id: event.resource_id,
        context: {
          user_id: m.user_id,
          rsvp: context.rsvps.find((r) => r.member_user_id === m.user_id) ?? null,
          // Surface the deadline metadata on each target so condition
          // evaluators that compare against the deadline (Phase 4) can
          // read it without re-fetching the resource.
          rsvp_deadline:   event.payload?.rsvp_deadline ?? null,
          event_starts_at: event.payload?.starts_at
            ?? context.resource?.metadata?.starts_at
            ?? null,
        },
      }));
  },

  // (V1) Single target = the member who checked in.
  checkInRecorded: async (event, _rule, context) => {
    if (!event.member_id) return [];
    const checkIn = context.checkIns.find((c) => {
      const m = context.members.find((x) => x.id === event.member_id);
      return m && c.member_user_id === m.user_id;
    });
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        check_in: checkIn,
        minutes_late: checkIn?.minutes_late ?? null,
      },
    }];
  },

  // (V1) Single target = the member who flipped their RSVP same-day.
  // event.member_id is null when iOS emits without resolving group_members.id.
  // Sprint 1c fix: fall back to event.payload.user_id (the auth.uid the iOS
  // coordinator includes), looking up the matching group_members row.
  rsvpChangedSameDay: async (event, _rule, context) => {
    let memberId = event.member_id;
    if (!memberId) {
      const userId = (event.payload?.user_id as string | undefined) ?? null;
      if (userId) {
        memberId = context.members.find((m) => m.user_id === userId)?.id ?? null;
      }
    }
    if (!memberId) return [];
    return [{
      member_id: memberId,
      resource_id: event.resource_id,
      context: { ...event.payload },
    }];
  },

  // (V1) Single target = the host (responsible for the menu/description).
  hoursBeforeEvent: async (event, _rule, context) => {
    const hostId = context.resource?.metadata?.host_id as UUID | undefined;
    if (!hostId) return [];
    const hostMember = context.members.find((m) => m.user_id === hostId);
    if (!hostMember) return [];
    return [{
      member_id: hostMember.id,
      resource_id: event.resource_id,
      context: {
        scheduled_hours: event.payload.hours,
        description: context.resource?.metadata?.description ?? null,
      },
    }];
  },

  // (mig 00193) Single target = the recorder of the ledger entry.
  // The DB trigger `ledger_entries_emit_atom` resolves the recorder's
  // group_members.id and sets it as event.member_id, plus pushes the full
  // ledger row into event.payload — so the condition evaluators
  // (`amountAbove`) can read amount_cents from target.context without a
  // round-trip to ledger_entries.
  ledgerEntryCreated: async (event, _rule, _context) => {
    if (!event.member_id) return [];
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        ledger_entry_id: event.payload.ledger_entry_id,
        type:            event.payload.type,
        amount_cents:    event.payload.amount_cents,
        currency:        event.payload.currency,
        from_member_id:  event.payload.from_member_id,
        to_member_id:    event.payload.to_member_id,
        source_atom_id:  event.id,
      },
    }];
  },

  // (Phase 2) Single target = the assigned holder of the expired slot.
  // The cron `emit-slot-system-events` projects assigned_member_id +
  // booking_id onto event.payload so the condition evaluators
  // (`slotIsUnassigned`) can read them from target.context without a
  // round-trip to the resource. If no member was assigned, no target —
  // an unassigned slot expiring without booking is a no-op (you can't
  // fine someone for not using a cupo they never held).
  slotExpired: async (event, _rule, _context) => {
    const assignedMemberId = (event.payload?.assigned_member_id as string | undefined) ?? null;
    if (!assignedMemberId) return [];
    if (!event.resource_id) return [];
    return [{
      member_id: assignedMemberId,
      resource_id: event.resource_id,
      context: {
        booking_id: (event.payload?.booking_id as string | null | undefined) ?? null,
        assigned_member_id: assignedMemberId,
        ends_at: event.payload?.ends_at ?? null,
        asset_id: event.payload?.asset_id ?? null,
      },
    }];
  },

  // (mig 00198 + 00199) Right resource_type lifecycle atoms. The atom
  // payloads carry the right-specific context the engine needs
  // (holder, delegate, target_capability, …) so condition evaluators
  // don't need to round-trip to the resource. Every evaluator below
  // projects the *current holder* as the rule target — that's the
  // member whose claim is being tracked, and it's what consequence
  // executors will fine/notify/transfer when relevant.
  //
  // event.resource_id is the right's id itself (not its target). The
  // right's target_resource_id (the asset the right governs) lives in
  // event.payload.target_resource_id when relevant.
  rightCreated: async (event, _rule, _context) => {
    const holderMemberId = (event.payload?.holder_member_id as string | undefined) ?? event.member_id;
    if (!holderMemberId || !event.resource_id) return [];
    return [{
      member_id: holderMemberId,
      resource_id: event.resource_id,
      context: {
        holder_member_id:   holderMemberId,
        target_resource_id: event.payload?.target_resource_id ?? null,
        target_capability:  event.payload?.target_capability ?? null,
        scope:              event.payload?.scope ?? null,
        priority:           event.payload?.priority ?? null,
        exclusive:          event.payload?.exclusive ?? null,
        transferable:       event.payload?.transferable ?? null,
        delegable:          event.payload?.delegable ?? null,
        divisible:          event.payload?.divisible ?? null,
        expires_at:         event.payload?.expires_at ?? null,
        source:             event.payload?.source ?? null,
        source_atom_id:     event.id,
      },
    }];
  },

  rightTransferred: async (event, _rule, _context) => {
    const toMemberId = (event.payload?.to_member_id as string | undefined) ?? event.member_id;
    if (!toMemberId || !event.resource_id) return [];
    return [{
      member_id: toMemberId,
      resource_id: event.resource_id,
      context: {
        from_member_id:  event.payload?.from_member_id ?? null,
        to_member_id:    toMemberId,
        transferred_by:  event.payload?.transferred_by ?? null,
        reason:          event.payload?.reason ?? null,
        source_atom_id:  event.id,
      },
    }];
  },

  rightDelegated: async (event, _rule, _context) => {
    const delegateMemberId = (event.payload?.delegate_member_id as string | undefined) ?? event.member_id;
    if (!delegateMemberId || !event.resource_id) return [];
    return [{
      member_id: delegateMemberId,
      resource_id: event.resource_id,
      context: {
        delegate_member_id: delegateMemberId,
        until:              event.payload?.until ?? null,
        delegated_by:       event.payload?.delegated_by ?? null,
        reason:             event.payload?.reason ?? null,
        source_atom_id:     event.id,
      },
    }];
  },

  // Revoke + Suspend + Restore: event.payload doesn't carry the holder
  // (the action targets the right, not a specific member). We resolve
  // the current holder from the resource so consequences (notification,
  // audit) can address the affected party.
  rightRevoked: async (event, _rule, context) => {
    const holderId = context.resource?.metadata?.holder_member_id as string | undefined;
    if (!event.resource_id) return [];
    return [{
      member_id: holderId ?? null,
      resource_id: event.resource_id,
      context: {
        previous_status: event.payload?.previous_status ?? null,
        revoked_by:      event.payload?.revoked_by ?? null,
        reason:          event.payload?.reason ?? null,
        source_atom_id:  event.id,
      },
    }];
  },

  rightSuspended: async (event, _rule, context) => {
    const holderId = context.resource?.metadata?.holder_member_id as string | undefined;
    if (!event.resource_id) return [];
    return [{
      member_id: holderId ?? null,
      resource_id: event.resource_id,
      context: {
        until:          event.payload?.until ?? null,
        suspended_by:   event.payload?.suspended_by ?? null,
        reason:         event.payload?.reason ?? null,
        source_atom_id: event.id,
      },
    }];
  },

  rightRestored: async (event, _rule, context) => {
    const holderId = context.resource?.metadata?.holder_member_id as string | undefined;
    if (!event.resource_id) return [];
    return [{
      member_id: holderId ?? null,
      resource_id: event.resource_id,
      context: {
        restored_by:    event.payload?.restored_by ?? null,
        reason:         event.payload?.reason ?? null,
        source_atom_id: event.id,
      },
    }];
  },

  // (mig 00199) Cron-emitted when metadata.expires_at <= now(). Holder
  // is in the payload (resolved by expire_due_rights). Useful for "warn
  // the holder X days before expiration"-style rules anchored on the
  // atom rather than a polling read.
  rightExpired: async (event, _rule, _context) => {
    const holderMemberId = (event.payload?.holder_member_id as string | undefined) ?? event.member_id;
    if (!event.resource_id) return [];
    return [{
      member_id: holderMemberId ?? null,
      resource_id: event.resource_id,
      context: {
        expired_at:       event.payload?.expired_at ?? null,
        holder_member_id: holderMemberId ?? null,
        name:             event.payload?.name ?? null,
        source:           event.payload?.source ?? null,
        source_atom_id:   event.id,
      },
    }];
  },

  rightExercised: async (event, _rule, _context) => {
    const exerciserMemberId = (event.payload?.exercised_by_member_id as string | undefined) ?? event.member_id;
    if (!event.resource_id) return [];
    return [{
      member_id: exerciserMemberId ?? null,
      resource_id: event.resource_id,
      context: {
        exercised_by_user_id:   event.payload?.exercised_by_user_id ?? null,
        exercised_by_member_id: exerciserMemberId ?? null,
        right_context:          event.payload?.context ?? {},
        source_atom_id:         event.id,
      },
    }];
  },

  // (mig 00203) Cron-emitted when an active right enters its pre-expiry
  // window (default 14 days, set in the cron schedule). The cron already
  // pre-computes holder_member_id + days_until_expiry into the payload
  // so the trigger evaluator + condition evaluator avoid a re-fetch of
  // the resource row. Drives `right_expiration_warning` template +
  // future "transfer-to-next-priority-on-expiry" style rules.
  rightExpiringSoon: async (event, _rule, _context) => {
    const holderMemberId = (event.payload?.holder_member_id as string | undefined) ?? event.member_id;
    if (!event.resource_id) return [];
    return [{
      member_id: holderMemberId ?? null,
      resource_id: event.resource_id,
      context: {
        expires_at:        event.payload?.expires_at ?? null,
        holder_member_id:  holderMemberId ?? null,
        name:              event.payload?.name ?? null,
        days_until_expiry: event.payload?.days_until_expiry ?? null,
        window_days:       event.payload?.window_days ?? null,
        source:            event.payload?.source ?? null,
        source_atom_id:    event.id,
      },
    }];
  },

  // (mig 00225-00227, AssetRules.md §4.1) Reporter is the single target.
  // Drives `damage_approval_required` + `damage_logged_warning` templates.
  // Payload trip-wire: severity + estimated_cost_cents flow into
  // target.context so `damageAmountAbove` + `requireApproval` /
  // `emitWarning` consequences read them without re-querying.
  damageReported: async (event, _rule, _context) => {
    if (!event.resource_id || !event.member_id) return [];
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        severity:              event.payload?.severity ?? null,
        estimated_cost_cents:  event.payload?.estimated_cost_cents ?? null,
        currency:              event.payload?.currency ?? null,
        notes:                 event.payload?.notes ?? null,
        source_atom_id:        event.id,
      },
    }];
  },

  // (mig 00225-00227, AssetRules.md §4.1) Member transferring is the target.
  // Drives `transfer_large_vote`. Projects `valuation_cents` from the
  // asset_valuation_view (via sink hook) so `transferAmountAbove` can
  // compare without a second round-trip from inside the condition.
  assetTransferred: async (event, _rule, context) => {
    if (!event.resource_id || !event.member_id) return [];
    const valuationCents = await context.sink.latestAssetValuationCents(event.resource_id);
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        to_member_id:    event.payload?.to_member_id ?? null,
        from_member_id:  event.payload?.from_member_id ?? null,
        transferred_by:  event.payload?.transferred_by ?? null,
        notes:           event.payload?.notes ?? null,
        valuation_cents: valuationCents,
        source_atom_id:  event.id,
      },
    }];
  },

  // (mig 00225-00227, AssetRules.md §4.1) Synthetic atom emitted by
  // emit-asset-overdue-events. member_id = the holder so `fine`
  // consequence routes to the right person. Drives `not_returned_fine`.
  assetCheckoutOverdue: async (event, _rule, _context) => {
    if (!event.resource_id || !event.member_id) return [];
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        expected_return_at: event.payload?.expected_return_at ?? null,
        checked_out_at:     event.payload?.checked_out_at ?? null,
        days_overdue:       event.payload?.days_overdue ?? null,
        source_atom_id:     event.id,
      },
    }];
  },

  // (mig 00225-00227, AssetRules.md §4.1) Synthetic atom emitted by
  // emit-asset-overdue-events. member_id = null (resource-scoped).
  // Drives `maintenance_overdue_lock`. The `lockBookings` consequence
  // reads target.resource_id, not target.member_id.
  assetMaintenanceOverdue: async (event, _rule, _context) => {
    if (!event.resource_id) return [];
    return [{
      member_id: null,
      resource_id: event.resource_id,
      context: {
        maintenance_event_id: event.payload?.maintenance_event_id ?? null,
        days_open:            event.payload?.days_open ?? null,
        logged_at:            event.payload?.logged_at ?? null,
        source_atom_id:       event.id,
      },
    }];
  },

  // ===========================================================================
  // Space rule triggers (mig 00268, Plans/Active/SpaceRules.md §3.1)
  // ===========================================================================

  // (PR-3) Emitted by book_space when a booking lands at capacity. Single
  // target = the booker. Drives `space_capacity_overflow_waitlist` template
  // (notifies group; UI then offers join_waitlist to subsequent bookers).
  // The atom is a signal — no obligation enumeration here.
  spaceCapacityReached: async (event, _rule, _context) => {
    if (!event.resource_id) return [];
    return [{
      member_id: event.member_id ?? null,
      resource_id: event.resource_id,
      context: {
        capacity:             event.payload?.capacity ?? null,
        triggered_booking_id: event.payload?.triggered_booking_id ?? null,
        source_atom_id:       event.id,
      },
    }];
  },

  // (PR-3) Emitted by cancel_booking. Single target = the original booker
  // (event.member_id, stamped by cancel_booking). Loads the booking row
  // to project starts_at into target.context so cancelledWithinHours can
  // compute hours-before-start without a re-fetch from inside the
  // condition evaluator. Drives `space_cancellation_late_fine`.
  bookingCancelled: async (event, _rule, context) => {
    if (!event.resource_id || !event.member_id) return [];
    const bookingId = event.payload?.booking_id as string | undefined;
    const bookingMeta = bookingId
      ? await context.sink.loadBookingMetadata(bookingId)
      : null;
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        booking_id:            bookingId ?? null,
        target_kind:           event.payload?.target_kind ?? bookingMeta?.target_kind ?? null,
        cancelled_by:          event.payload?.cancelled_by ?? null,
        reason:                event.payload?.reason ?? null,
        cancelled_at:          event.occurred_at,
        booking_starts_at:     bookingMeta?.starts_at ?? null,
        booking_ends_at:       bookingMeta?.ends_at ?? null,
        source_atom_id:        event.id,
      },
    }];
  },

  // (PR-3) Synthetic atom emitted by emit-space-no-check-in-events cron.
  // member_id = the booker (cron stamps it). Drives
  // `space_no_check_in_release` template — releaseBooking consequence
  // closes the claim. Payload already carries booking_id + starts_at +
  // minutes_overdue (the cron projects them) so no booking lookup needed.
  bookingNoCheckIn: async (event, _rule, _context) => {
    if (!event.resource_id || !event.member_id) return [];
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        booking_id:       event.payload?.booking_id ?? null,
        booking_starts_at: event.payload?.starts_at ?? null,
        minutes_overdue:  event.payload?.minutes_overdue ?? null,
        grace_minutes:    event.payload?.grace_minutes ?? null,
        source_atom_id:   event.id,
      },
    }];
  },

  // (PR-3) Emitted by book_space (and book_slot) every time a booking
  // is created. Single target = the booker. Projects starts_at + ends_at
  // + computed duration_minutes onto target.context so
  // bookingDurationAbove / outsideAllowedHours can read them. Drives
  // `space_outside_allowed_hours_deny` + `space_long_booking_vote`.
  bookingCreated: async (event, _rule, _context) => {
    if (!event.resource_id || !event.member_id) return [];
    const startsAtRaw = event.payload?.starts_at as string | undefined;
    const endsAtRaw   = event.payload?.ends_at as string | undefined;
    let durationMinutes: number | null = null;
    if (startsAtRaw && endsAtRaw) {
      const startMs = new Date(startsAtRaw).getTime();
      const endMs   = new Date(endsAtRaw).getTime();
      if (!Number.isNaN(startMs) && !Number.isNaN(endMs) && endMs > startMs) {
        durationMinutes = Math.floor((endMs - startMs) / 60_000);
      }
    }
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        booking_id:                event.payload?.booking_id ?? null,
        target_kind:               event.payload?.target_kind ?? null,
        booking_starts_at:         startsAtRaw ?? null,
        booking_ends_at:           endsAtRaw ?? null,
        booking_duration_minutes:  durationMinutes,
        source_atom_id:            event.id,
      },
    }];
  },

  // (PR-3) Emitted by join_waitlist. Single target = the joiner. Projects
  // priority + actor_roles + actor_permissions (V7) into target.context
  // so actorHasRole / actorHasPermission / bumpPriority can read without
  // re-fetching the member row. Drives `space_founder_priority_bump` +
  // future permission-gated templates.
  spaceWaitlistJoined: async (event, _rule, context) => {
    if (!event.resource_id || !event.member_id) return [];
    const [actorRoles, actorPermissions] = await Promise.all([
      context.sink.loadMemberRoles(event.member_id),
      context.sink.loadMemberPermissions(event.member_id),
    ]);
    return [{
      member_id: event.member_id,
      resource_id: event.resource_id,
      context: {
        priority:          event.payload?.priority ?? 0,
        joined_at:         event.payload?.joined_at ?? event.occurred_at,
        actor_roles:       actorRoles,
        actor_permissions: actorPermissions,
        source_atom_id:    event.id,
      },
    }];
  },
};
