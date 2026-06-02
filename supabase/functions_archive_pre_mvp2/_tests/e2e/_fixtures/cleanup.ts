// Cleanup helpers for E2E tests. Tests use unique group_ids + emails so
// collisions across runs are impossible, but we still tidy up so the
// local DB doesn't accumulate cruft over many runs.
//
// Order respects FKs: child tables → parent tables. Most tables CASCADE
// from groups, but explicit deletion makes the test more robust to schema
// drift (e.g. someone changes ON DELETE behavior in a future migration).

import { adminClient, deleteTestUser } from "./supabaseClients.ts";
import type { SeededGroup } from "./seedGroup.ts";

export async function cleanupGroup(group: SeededGroup): Promise<void> {
  const admin = adminClient();
  const groupId = group.groupId;

  // Order: notifications → vote_casts → votes → fines → fine_review_periods
  //      → system_events → event_attendance → events → rules → group_members → groups
  // group_members has FK to auth.users, so users delete after.
  const tables = [
    "notifications_outbox",
    "vote_casts",
    "votes",
    "fines",
    "fine_review_periods",
    "system_events",
    "event_attendance",
    "events",
    "rules",
    "group_members",
    "groups",   // delete the group last; FK CASCADE handles stragglers
  ];

  for (const table of tables) {
    if (table === "groups") {
      await admin.from(table).delete().eq("id", groupId);
    } else {
      // Some tables may not have group_id directly (e.g. vote_casts).
      // Try group_id first; if the column doesn't exist the call errors
      // gracefully and we skip — orphans get caught by group CASCADE.
      const res = await admin.from(table).delete().eq("group_id", groupId);
      if (res.error && !res.error.message.includes("column")) {
        console.warn(`[e2e cleanup] ${table} delete failed: ${res.error.message}`);
      }
    }
  }

  // Drop the auth users last
  for (const m of group.members) {
    await deleteTestUser(m.userId);
  }
}
