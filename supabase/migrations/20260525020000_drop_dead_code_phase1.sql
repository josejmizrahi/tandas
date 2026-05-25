-- Backend Dead Code Phase 1 — Drop superseded / orphan public RPCs.
--
-- See Plans/Active/BackendDeadCodeAudit.md for methodology and audit trail.
--
-- Each drop verified to have:
--   • Zero iOS .rpc() callers (grep ios/Packages/**/*.swift)
--   • Zero edge function .rpc() callers (grep supabase/functions/**/*.ts, excl. _tests/)
--   • Zero cron.job entries (select * from cron.job)
--   • Zero internal DB callers (pg_proc.prosrc cross-reference scan)
--
-- All drops use `IF EXISTS` so the migration is idempotent. None use CASCADE
-- because the audit confirmed no dependent objects — if a dependent slipped
-- through, the migration fails loudly rather than cascading silently.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- Section 1 — Superseded variants
-- ─────────────────────────────────────────────────────────────────────────

-- Superseded by `create_resource_rule(p_group_id, p_resource_id, …)` which
-- is polymorphic across all resource types. The event-only variant was a
-- legacy from the pre-resource-polymorphism era.
DROP FUNCTION IF EXISTS public.create_event_rule(
    uuid, uuid, text, jsonb, jsonb, jsonb
);

-- Superseded by `list_resource_rules_with_inherited(p_resource_id)`. Same
-- shape, polymorphic across resource types.
DROP FUNCTION IF EXISTS public.list_event_rules_with_inherited(uuid);

-- Superseded by per-property setters + `groups.governance` jsonb writes +
-- `set_group_module()` for module toggles. The mega-update wrapper had no
-- callers post-doctrine.
DROP FUNCTION IF EXISTS public.update_group_config(
    uuid, text, text, jsonb, boolean, text, text, jsonb
);

-- ─────────────────────────────────────────────────────────────────────────
-- Section 2 — Orphan utilities (never wired into a feature)
-- ─────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_placeholder_history_summary(uuid);

DROP FUNCTION IF EXISTS public.list_member_permissions(uuid);

DROP FUNCTION IF EXISTS public.list_members_with_permission(uuid, text);

-- One-shot backfill helper used during the shared-money migration rollout.
-- Already executed against all existing groups; future groups get their
-- shared pool seeded via the `seed_policies_on_group_insert` trigger.
DROP FUNCTION IF EXISTS public.seed_shared_pool_for_existing_group(uuid);

COMMIT;

-- ─────────────────────────────────────────────────────────────────────────
-- NOT INCLUDED in this migration (require separate decisions):
-- ─────────────────────────────────────────────────────────────────────────
--
-- Test functions in `public` schema (decision: move to test_ schema vs drop):
--   • test_checkinmissed_emission(uuid, uuid, uuid, uuid)
--   • test_hostassigned_atom_emission(uuid, uuid, uuid)
--   • test_rsvp_atom_emission(uuid, uuid, uuid)
--
-- Edge functions to pause/delete (operational, not SQL):
--   • generate-wallet-pass    — pre-pivot Apple Wallet PassKit
--   • export-user-data        — superseded by RPC `export_my_data`
--   • finalize-appeal-votes   — superseded by `finalize-fine-reviews`+`finalize-votes`
--
-- Medium-confidence drops (need exhaustive grep first, see audit doc §4):
--   • remove_member, set_turn_order, regenerate_invite_code, accept_placeholder_claim,
--     decline_placeholder_claim, request_data_export, request_data_rectification,
--     claim_pending_outbox
--
-- Note: original audit flagged `.rpc("check_in_attendee")` as a production
-- edge-fn bug. Re-checked — all 4 matches were in `_tests/e2e/`, not in
-- runtime edge fns. Migrated tests to `check_in_v2` in PR-08 (see audit doc).
