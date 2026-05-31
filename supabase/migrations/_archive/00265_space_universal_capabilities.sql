-- 00265 — Space universal capabilities (Plans/Active/Space.md §16).
--
-- Two new platform capabilities + space coverage extension on three
-- pre-existing ones. Companion of mig 00264 (atoms) and mig 00266 (RPCs).
--
-- New capabilities (2):
--   availability — consult free windows on a space (read-side)
--   waitlist     — ordered queue when capacity is full
--
-- Existing capabilities extended to include `space`:
--   ledger / money / rules — Space.md §16 lists them as stable shared.
--                            They were not in mig 00207 because space did
--                            not yet have lifecycle RPCs that could touch
--                            ledger or fire rule-engine atoms.
--
-- Why not `access_control`?
--   Founder directive 2026-05-18 — reuse existing `access` capability
--   (mig 00208, asset spec §16, already includes space). One concept,
--   one cap. Avoids catalog duplication.
--
-- Catalog write-lock (mig 00191) doesn't apply to migration role.
-- All seeds use `on conflict do update` so re-running is a no-op for
-- existing rows.

-- =============================================================================
-- 1. New capabilities — availability + waitlist
-- =============================================================================

insert into public.capabilities (
  id, display_name, summary, status, enabled_resource_types, dependencies
) values
  (
    'availability',
    'Disponibilidad',
    'Consulta ventanas libres del espacio. Deriva de bookings activos y rules.',
    'stable',
    array['space', 'slot'],
    array['booking']
  ),
  (
    'waitlist',
    'Lista de espera',
    'Cola ordenada de miembros cuando el espacio llega al aforo.',
    'stable',
    array['space'],
    array['capacity']
  )
on conflict (id) do update set
  display_name           = excluded.display_name,
  summary                = excluded.summary,
  status                 = excluded.status,
  enabled_resource_types = excluded.enabled_resource_types,
  dependencies           = excluded.dependencies,
  updated_at             = now();

-- =============================================================================
-- 2. Extend `space` coverage on existing capabilities
-- =============================================================================
-- Idempotent: only appends `space` when missing.

update public.capabilities
   set enabled_resource_types = array_append(enabled_resource_types, 'space'),
       updated_at = now()
 where id in ('ledger', 'money', 'rules')
   and not ('space' = any (enabled_resource_types));
