// Assertion helpers for E2E tests. Each one queries via service-role
// (bypassing RLS) and asserts a specific contract — state, causal chain,
// or notifications. Designed to fail with informative messages so test
// debugging doesn't require digging into raw rows.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./supabaseClients.ts";

const admin = adminClient();

// =============================================================================
// Level 1: state
// =============================================================================

export interface FineAssertion {
  fineId?: string;
  groupId: string;
  userId: string;            // who should be fined
  expectedStatus: "proposed" | "officialized" | "voided" | "in_appeal" | "paid";
  expectedAmount: number;
}

export async function assertFineState(a: FineAssertion): Promise<{ id: string; rule_id: string }> {
  // §14 Step 3b: read from fines_view so assertions see derived status
  // (paid/voided/in_appeal/officialized) consistent with the projection
  // that production iOS clients read.
  let q = admin.from("fines_view").select("id, status, amount, rule_id")
    .eq("group_id", a.groupId)
    .eq("user_id",  a.userId);
  if (a.fineId) q = q.eq("id", a.fineId);

  const { data, error } = await q.single();
  if (error || !data) {
    throw new Error(`assertFineState: no fine for user ${a.userId} in group ${a.groupId}: ${error?.message}`);
  }
  assertEquals(data.status, a.expectedStatus, `fine.status expected ${a.expectedStatus}, got ${data.status}`);
  assertEquals(data.amount, a.expectedAmount, `fine.amount expected ${a.expectedAmount}, got ${data.amount}`);
  return { id: data.id, rule_id: data.rule_id };
}

export async function assertVoteResolution(args: {
  voteId: string;
  expectedResolution: "passed" | "failed" | "quorum_failed";
  expectedStatus: "resolved" | "quorum_failed";
}): Promise<void> {
  const { data, error } = await admin
    .from("votes")
    .select("status, counts, payload")
    .eq("id", args.voteId)
    .single();
  if (error || !data) {
    throw new Error(`assertVoteResolution: vote ${args.voteId} not found: ${error?.message}`);
  }
  assertEquals(data.status, args.expectedStatus, `vote.status expected ${args.expectedStatus}, got ${data.status}`);
  const resolution = (data.payload as Record<string, unknown>)?.resolution
    ?? (data.counts as Record<string, unknown>)?.resolution;
  assertEquals(resolution, args.expectedResolution, `vote.resolution expected ${args.expectedResolution}, got ${resolution}`);
}

// =============================================================================
// Level 2: causal chain via system_events
// =============================================================================

/**
 * Asserts the system_events for a group, in occurred_at order, contain the
 * expected event_type sequence as a SUBSEQUENCE. Other event types
 * interleaved are tolerated (we only require the target chain is in order).
 *
 * Reason for subsequence semantics: process-system-events may emit
 * intermediate or housekeeping events we don't care about; we only assert
 * that A precedes B precedes C.
 */
export async function assertCausalChain(args: {
  groupId: string;
  expectedSubsequence: string[];
}): Promise<void> {
  const { data, error } = await admin
    .from("system_events")
    .select("event_type, occurred_at")
    .eq("group_id", args.groupId)
    .order("occurred_at", { ascending: true });
  if (error) {
    throw new Error(`assertCausalChain: query failed: ${error.message}`);
  }
  const actual = (data ?? []).map((r: { event_type: string }) => r.event_type);
  let cursor = 0;
  for (const ev of actual) {
    if (cursor < args.expectedSubsequence.length && ev === args.expectedSubsequence[cursor]) {
      cursor++;
    }
  }
  if (cursor < args.expectedSubsequence.length) {
    throw new Error(
      `assertCausalChain: expected subsequence ${JSON.stringify(args.expectedSubsequence)} ` +
      `not found in actual events ${JSON.stringify(actual)}. ` +
      `Stuck at expected[${cursor}]=${args.expectedSubsequence[cursor]}`,
    );
  }
}

// =============================================================================
// Level 3: notifications_outbox
// =============================================================================

/**
 * Asserts the outbox contains exactly the (recipient, type) pairs given
 * for this group. Order is not asserted — multiple notifications of the
 * same type are deduped before comparison so the test isn't sensitive to
 * fan-out timing.
 */
export async function assertNotifications(args: {
  groupId: string;
  expected: { recipientMemberId: string; notificationType: string }[];
}): Promise<void> {
  const { data, error } = await admin
    .from("notifications_outbox")
    .select("recipient_member_id, notification_type")
    .eq("group_id", args.groupId);
  if (error) {
    throw new Error(`assertNotifications: query failed: ${error.message}`);
  }
  const actual = (data ?? []).map((r: { recipient_member_id: string; notification_type: string }) =>
    `${r.recipient_member_id}:${r.notification_type}`
  );
  const actualSet = new Set(actual);

  for (const exp of args.expected) {
    const key = `${exp.recipientMemberId}:${exp.notificationType}`;
    if (!actualSet.has(key)) {
      throw new Error(
        `assertNotifications: missing ${key}. Got: ${JSON.stringify(actual)}`,
      );
    }
  }
}

/** Reads the count of system_events of a given type for a group. */
export async function countSystemEvents(groupId: string, eventType: string): Promise<number> {
  const { count, error } = await admin
    .from("system_events")
    .select("*", { count: "exact", head: true })
    .eq("group_id", groupId)
    .eq("event_type", eventType);
  if (error) throw new Error(`countSystemEvents: ${error.message}`);
  return count ?? 0;
}
