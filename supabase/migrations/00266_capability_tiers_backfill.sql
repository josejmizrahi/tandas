-- Mig 00231: backfill Tier 0 + Tier 0.5 capabilities on all existing
-- resources per the new canonical doctrine in
-- `Plans/Active/CapabilityTiers.md`.
--
-- Background
-- ==========
-- The iOS catalog (`CapabilityCatalog.swift`) was previously gated
-- inconsistently: `status`, `description`, `history`, `voting` were
-- universal across the 6 resource_types, but `rules`, `ledger`, `money`
-- were restricted to `[event, slot, fund]` from Phase 1/2 priorities.
-- This was accidental, not doctrinal.
--
-- The catalog edits in this commit promote:
--   * `rules`, `consequence` → universal (all 6 types — Tier 0)
--   * `ledger`, `money`      → economic universals (event/fund/asset/
--                              space/slot, no `right` — Tier 0.5)
--   * `valuation`            → asset/fund only (removed `right`)
--
-- Going forward every new resource picks these up via the builder
-- `withTierDefaults()` helper. THIS migration is the one-shot backfill
-- so resources created before the catalog change end up consistent.
--
-- Idempotency
-- ===========
-- INSERT ... ON CONFLICT DO NOTHING. Re-runs are no-ops. Resources that
-- already had the capability are left untouched (no overwrite of config).
--
-- Provenance
-- ==========
-- `enabled_by` is NOT NULL with no migration-time auth context. We use
-- the resource's own `created_by` so the backfill row attributes the
-- enablement to whoever owned the resource — preserving the chain of
-- custody.
--
-- valuation cleanup
-- =================
-- The catalog no longer sanctions `valuation` on `right`. We do NOT
-- delete existing `valuation` rows on right resources (destructive +
-- prod has zero rights with valuation today). New rights simply won't
-- gain it. If a future migration needs to enforce the catalog as
-- ground truth, write a dedicated cleanup with explicit opt-in.

BEGIN;

-- ============================================================
-- Tier 0 — universals (all 6 resource types)
-- ============================================================
-- status, description, history are usually present (universal in the
-- catalog from day one). rules + voting are the ones that historically
-- missed asset/space/slot/right.

INSERT INTO public.resource_capabilities (
  resource_id, capability_block_id, config, enabled,
  enabled_at, enabled_by
)
SELECT
  r.id,
  cap.block_id,
  '{}'::jsonb,
  true,
  now(),
  r.created_by
FROM public.resources r
CROSS JOIN (VALUES
  ('status'), ('description'), ('history'), ('rules'), ('voting')
) AS cap(block_id)
WHERE r.archived_at IS NULL
ON CONFLICT (resource_id, capability_block_id) DO NOTHING;

-- ============================================================
-- Tier 0.5 — economic universals (event/fund/asset/space/slot)
-- ============================================================
-- ledger + money for every resource whose type can host money atoms.
-- `right` excluded by doctrine (CapabilityTiers.md §3).

INSERT INTO public.resource_capabilities (
  resource_id, capability_block_id, config, enabled,
  enabled_at, enabled_by
)
SELECT
  r.id,
  cap.block_id,
  '{}'::jsonb,
  true,
  now(),
  r.created_by
FROM public.resources r
CROSS JOIN (VALUES ('ledger'), ('money')) AS cap(block_id)
WHERE r.archived_at IS NULL
  AND r.resource_type IN ('event', 'fund', 'asset', 'space', 'slot')
ON CONFLICT (resource_id, capability_block_id) DO NOTHING;

-- ============================================================
-- valuation — asset + fund only
-- ============================================================
-- Pre-existing assets/funds likely have valuation already (mig 00199
-- shipped the cap for asset by default). Backfill any holdouts.

INSERT INTO public.resource_capabilities (
  resource_id, capability_block_id, config, enabled,
  enabled_at, enabled_by
)
SELECT
  r.id,
  'valuation',
  '{}'::jsonb,
  true,
  now(),
  r.created_by
FROM public.resources r
WHERE r.archived_at IS NULL
  AND r.resource_type IN ('asset', 'fund')
ON CONFLICT (resource_id, capability_block_id) DO NOTHING;

-- ============================================================
-- Surface the backfill counts in apply log so we can confirm.
-- ============================================================
DO $$
DECLARE
  v_total int;
  v_by_block jsonb;
BEGIN
  SELECT count(*) INTO v_total
    FROM public.resource_capabilities;
  SELECT jsonb_object_agg(capability_block_id, n)
    INTO v_by_block
    FROM (
      SELECT capability_block_id, count(*) AS n
        FROM public.resource_capabilities
       WHERE capability_block_id IN ('status','description','history',
                                     'rules','voting','ledger','money','valuation')
       GROUP BY capability_block_id
       ORDER BY capability_block_id
    ) t;
  RAISE NOTICE 'mig 00266: % total resource_capabilities rows post-backfill; tier 0/0.5 distribution = %',
    v_total, v_by_block;
END;
$$;

COMMIT;
