// Beta 1 Consolidation W1-2 — monetary fines from the recurring_dinner
// template MUST land with is_active=false at group creation time, so
// new groups don't enter a punitive state without explicit founder
// consent.
//
// Background: a parent that taps "Reuniones recurrentes" used to land
// with $200/$200/$200/$300 MXN fines silently armed before they'd seen
// any rule in the UI. First time they'd discover them was via a
// proposed fine in their inbox — instant trust breach.
//
// Policy: reminders (soft, non-monetary) may ship ON; anything that
// touches money must ship OFF and require an explicit toggle. This
// is enforced at the module-rule seed layer
// (`modules.basic_fines.provided_rules_def`).
//
// Test asserts the post-seed invariant directly, without going through
// the rule-engine: after a fresh `create_group_with_admin` for the
// canonical recurring_dinner template, ALL monetary-fine rules in
// public.rules must be `is_active=false`.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { adminClient } from "./_fixtures/supabaseClients.ts";
import { seedGroup, type SeededGroup } from "./_fixtures/seedGroup.ts";
import { cleanupGroup } from "./_fixtures/cleanup.ts";

const admin = adminClient();

Deno.test("dinner template: monetary fines land with is_active=false", async () => {
  let group: SeededGroup | null = null;
  try {
    group = await seedGroup({
      memberSpecs: [{ handle: "alice" }],
      // baseTemplate defaults to "recurring_dinner" in seedGroup —
      // explicit here for clarity.
      baseTemplate: "recurring_dinner",
    });

    // Pull all rules for this group.
    const { data: rules, error } = await admin
      .from("rules")
      .select("slug, name, is_active, consequences")
      .eq("group_id", group.groupId);
    if (error) throw new Error(`select rules: ${error.message}`);
    if (!rules || rules.length === 0) {
      throw new Error("seedGroup left zero rules on the new group");
    }

    // Partition into monetary vs non-monetary.
    const monetary: typeof rules = [];
    const nonMonetary: typeof rules = [];
    for (const r of rules) {
      const conseq = (r.consequences ?? []) as Array<{ type?: string }>;
      const hasFine = conseq.some((c) => c.type === "fine");
      (hasFine ? monetary : nonMonetary).push(r);
    }

    // Invariant: every monetary fine must be inactive at seed time.
    const activeMonetary = monetary.filter((r) => r.is_active === true);
    assertEquals(
      activeMonetary.length,
      0,
      `Expected zero monetary fines active at seed time; got ${activeMonetary.length}: ${
        activeMonetary.map((r) => r.slug).join(", ")
      }`,
    );

    // Sanity: the dinner template SHOULD ship monetary-fine rules
    // (just inactive). If this collapses to zero, the seed regressed.
    if (monetary.length === 0) {
      throw new Error(
        "Dinner template emitted no monetary-fine rules at all — seed regressed",
      );
    }
  } finally {
    if (group) await cleanupGroup(group);
  }
});
