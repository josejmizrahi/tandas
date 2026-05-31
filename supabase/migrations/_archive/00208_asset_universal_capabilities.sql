-- Mig 00199 — Asset universal capabilities (canonical asset spec).
--
-- The canonical asset spec (§8) lists the capabilities every asset
-- can wear:
--
--   booking, custody, inventory, maintenance, valuation, transfer,
--   access, delegation, approvals, voting
--
-- Pre-00199 catalog had only the partial set the palco-shape needed:
--   booking, capacity, guest_access, voting, status, description,
--   location, history.
--
-- This migration registers the missing 7 universal blocks so any
-- asset (car, speakers, NFT, equity, IP, hardware, document, …) can
-- opt into them. Spec §17 framing: inventory is a CAPABILITY on an
-- asset, not a separate resource_type.
--
-- The catalog's contract per Constitution Article 5: "Capabilities
-- son primitivas de comportamiento. Universales, platform-level."
-- Each block declares the resource_types it can attach to so the
-- iOS wizard, the rule engine, and analytics can reason uniformly.
--
-- Status policy:
-- - `custody` is `stable` — the assign_custody / release_custody
--   RPCs ship in mig 00200 alongside the projection
--   `asset_current_custodian_view` (00201).
-- - `maintenance`, `valuation`, `transfer` are `stable` — RPCs +
--   projections ship in this same release.
-- - `access` and `delegation` are `incomplete` — design-time
--   declared, runtime path lands in a follow-up. Spec §8 already
--   names them so the catalog has to acknowledge them; iOS hides
--   incomplete blocks from the wizard per the existing
--   CapabilityStatus contract.
-- - `inventory` is `stable` — the asset's `metadata.inventory_count`
--   + `metadata.unit_label` carry the projection; mig 00201 wires
--   `asset_inventory_view`.
--
-- Existing `voting` already covers the canonical 6 resource types
-- (mig 00165) so no duplicate row needed here.

insert into public.capabilities (
  id,
  display_name,
  summary,
  status,
  enabled_resource_types,
  dependencies
) values
  (
    'custody',
    'Custodia',
    'Quién tiene físicamente el activo (separado de la propiedad).',
    'stable',
    array['asset'],
    array[]::text[]
  ),
  (
    'maintenance',
    'Mantenimiento',
    'Reportar daños, registrar reparaciones, recordar service.',
    'stable',
    array['asset', 'space'],
    array[]::text[]
  ),
  (
    'valuation',
    'Valuación',
    'Registrar el valor del activo en el tiempo.',
    'stable',
    array['asset', 'fund', 'right'],
    array[]::text[]
  ),
  (
    'transfer',
    'Transferencia',
    'Mover ownership del activo a otro miembro o al grupo.',
    'stable',
    array['asset', 'right'],
    array[]::text[]
  ),
  (
    'access',
    'Acceso',
    'Quién puede usar el activo y bajo qué condiciones.',
    'incomplete',
    array['asset', 'space', 'right'],
    array[]::text[]
  ),
  (
    'delegation',
    'Delegación',
    'Prestar el activo temporalmente a un no-custodio.',
    'incomplete',
    array['asset', 'right'],
    array['custody']
  ),
  (
    'inventory',
    'Inventario',
    'Contar unidades del activo (stock, cupos, copias).',
    'stable',
    array['asset'],
    array[]::text[]
  )
on conflict (id) do update set
  display_name           = excluded.display_name,
  summary                = excluded.summary,
  status                 = excluded.status,
  enabled_resource_types = excluded.enabled_resource_types,
  dependencies           = excluded.dependencies,
  updated_at             = now();

-- =============================================================================
-- Extend existing universal capabilities to include `asset` where the
-- canonical spec applies. The spec frames booking as universal across
-- {space, slot, asset} (already correct); guest_access on assets
-- (spec §8 — palcos with invitados, herramientas con préstamo); and
-- capacity on assets (spec §17 — inventory).
-- =============================================================================

-- These rows already enable .asset; no extension needed:
--   booking          (slot, asset)         — mig 00165
--   capacity         (event, slot, asset, right) — mig 00165
--   guest_access     (event, slot, asset)  — mig 00165
--   voting           (canonical 6)          — mig 00165
--   status           (canonical 6)          — mig 00165
--   description      (canonical 6)          — mig 00165
--   location         (event, slot, asset)  — mig 00165
--   history          (canonical 6)          — mig 00165

comment on table public.capabilities is
  'Global capability catalog (35 stable entries post-00199). Read-only for authenticated; writes only via migrations or service_role one-offs.';
