-- 00065 — Phase 2 modules: slot_assignment, rotating_position,
-- slot_swap_request.
--
-- Insert into the canonical `public.modules` catalog (mig 00060).
-- Cascade closures are computed dynamically by `set_group_module`
-- (mig 00061) — no separate closure migration needed here.
--
-- Module declarations (mirror what iOS V1Modules.swift would
-- declare for these three; iOS code reads via `list_modules()` so
-- the Swift fallback can be added later without lockstep).
--
-- Conflict matrix: `rotating_position` conflicts with V1's
-- `rotating_host` — both compete for the "who is on duty" axis. A
-- group can run one or the other, not both. iOS validation gates
-- this at the toggle UI; a future migration adds server-side
-- conflict enforcement to set_group_module (deferred — V1 had no
-- conflicts so the enforcement layer was never built).

insert into public.modules (
  id, name, description,
  provided_rules, provided_resource_types,
  provided_system_event_types, provided_tabs,
  dependencies, conflicts_with
) values
  (
    'slot_assignment',
    'Asignación de cupos',
    'Asigna y revoca cupos sobre Assets compartidos (palco, casa, cancha). Habilita rules sobre slots no usados, expirations, y multas por no liberar a tiempo.',
    array[]::text[],
    array['slot','booking','asset']::text[],
    array['slotAssigned','slotDeclined','slotExpired','bookingCreated','bookingCancelled','bookingExpired','assetCreated']::text[],
    array[]::text[],
    array[]::text[],
    array[]::text[]
  ),
  (
    'rotating_position',
    'Posición rotativa',
    'Mantiene un orden rotativo sobre Members o Resources (host actual, equipo de la semana, encargado del fondo). Más general que rotating_host: cualquier "a quién le toca".',
    array[]::text[],
    array['position','assignment','rotation']::text[],
    array['positionChanged']::text[],
    array[]::text[],
    array[]::text[],
    array['rotating_host']::text[]
  ),
  (
    'slot_swap_request',
    'Cambio de cupos',
    'Permite a miembros pedir intercambio de cupos asignados. La aprobación pasa por vote o por consentimiento del titular original según governance.',
    array[]::text[],
    array[]::text[],
    array['slotSwapRequested','slotSwapApproved']::text[],
    array[]::text[],
    array['slot_assignment']::text[],
    array[]::text[]
  )
on conflict (id) do update set
  name                        = excluded.name,
  description                 = excluded.description,
  provided_rules              = excluded.provided_rules,
  provided_resource_types     = excluded.provided_resource_types,
  provided_system_event_types = excluded.provided_system_event_types,
  provided_tabs               = excluded.provided_tabs,
  dependencies                = excluded.dependencies,
  conflicts_with              = excluded.conflicts_with,
  updated_at                  = now();
