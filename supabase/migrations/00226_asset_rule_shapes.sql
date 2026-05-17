-- Mig 00226 — Asset rule shapes (Plans/Active/AssetRules.md §3)
--
-- Registers the trigger / condition / consequence shape pieces the
-- Beta 1 Rule Builder needs to compose asset-specific rules. The five
-- canonical templates (`damage_approval_required`, `not_returned_fine`,
-- `maintenance_overdue_lock`, `transfer_large_vote`,
-- `damage_logged_warning`) seed in mig 00227 — this migration ships
-- ONLY the catalog rows so the Builder gallery can render the chips
-- and the rule engine can find the corresponding evaluators by id.
--
-- Pieces added:
--
--   triggers (4 new):
--     damageReported       — asset.damageReported emitted by report_damage RPC
--     assetTransferred     — asset.transferred emitted by transfer_asset RPC
--     checkoutOverdue      — synthetic, emitted by emit-asset-overdue-events cron
--     maintenanceOverdue   — synthetic, emitted by emit-asset-overdue-events cron
--
--   conditions (2 new):
--     damageAmountAbove    — filters on payload.estimated_cost_cents > threshold
--     transferAmountAbove  — filters on target.context.valuation_cents > threshold
--
--   consequences (2 new):
--     requireApproval      — inserts a user_actions row of action_type
--                            'assetActionApproval' for admins to action
--     lockBookings         — flips resources.metadata.bookings_locked = true +
--                            emits a `bookingLockEnabled` warning atom for audit
--
-- All entries use the same INSERT/ON CONFLICT shape as mig 00211 so
-- re-runs are idempotent. iOS reads these via `list_rule_shapes()`.
--
-- The engine evaluators that consume these shape ids live in
-- supabase/functions/_shared/ruleEngine.ts (extended in the same
-- commit as this migration). Without those evaluators a rule
-- composed from these shapes parses fine but produces zero effects —
-- the catalog row is the metadata, the evaluator is the behavior.

-- =============================================================================
-- 1. Trigger shapes
-- =============================================================================

insert into public.rule_shapes (
  id, kind, label_es, summary_es, icon,
  valid_scopes, valid_resource_types, config_fields, sort_order
) values
  ('damageReported',
   'trigger',
   'Cuando se reporta un daño',
   'Se dispara cuando alguien reporta un daño sobre el activo. El payload trae severidad + costo estimado.',
   'exclamationmark.triangle',
   array['resource','group']::text[],
   array['asset']::text[],
   '[]'::jsonb,
   200),
  ('assetTransferred',
   'trigger',
   'Cuando se transfiere el activo',
   'Se dispara cada vez que cambia la propiedad del activo (a otro miembro o de vuelta al grupo).',
   'arrow.left.arrow.right.circle',
   array['resource','group']::text[],
   array['asset']::text[],
   '[]'::jsonb,
   210),
  ('checkoutOverdue',
   'trigger',
   'Cuando no devuelven el activo a tiempo',
   'Se dispara cuando pasa la fecha de devolución esperada y nadie marcó el activo como devuelto. Configura los días de tolerancia.',
   'clock.badge.exclamationmark',
   array['resource','group']::text[],
   array['asset']::text[],
   '[{"key":"grace_days","kind":"int","label_es":"Días de tolerancia","placeholder":"1","min":0,"max":30,"defaultValue":1}]'::jsonb,
   220),
  ('maintenanceOverdue',
   'trigger',
   'Cuando un mantenimiento queda abierto demasiado tiempo',
   'Se dispara cuando un mantenimiento registrado no se cierra en X días. Útil para escalar service overdue.',
   'wrench.and.screwdriver',
   array['resource','group']::text[],
   array['asset']::text[],
   '[{"key":"days","kind":"int","label_es":"Días sin cerrar","placeholder":"7","min":1,"max":90,"defaultValue":7}]'::jsonb,
   230)
on conflict (id) do update set
  label_es = excluded.label_es,
  summary_es = excluded.summary_es,
  icon = excluded.icon,
  valid_scopes = excluded.valid_scopes,
  valid_resource_types = excluded.valid_resource_types,
  config_fields = excluded.config_fields,
  sort_order = excluded.sort_order;

-- =============================================================================
-- 2. Condition shapes
-- =============================================================================

insert into public.rule_shapes (
  id, kind, label_es, summary_es, icon,
  valid_scopes, valid_resource_types, config_fields, sort_order
) values
  ('damageAmountAbove',
   'condition',
   'Solo si el costo del daño supera $X',
   'Filtra para que la regla aplique únicamente cuando el costo estimado del daño supere el umbral.',
   'banknote.fill',
   array[]::text[],
   array[]::text[],
   '[{"key":"threshold_cents","kind":"currency","label_es":"Umbral en MXN","placeholder":"5000","min":1,"max":100000000,"defaultValue":500000}]'::jsonb,
   200),
  ('transferAmountAbove',
   'condition',
   'Solo si la valuación del activo supera $X',
   'Filtra para que la regla aplique únicamente cuando la última valuación registrada supere el umbral.',
   'chart.line.uptrend.xyaxis',
   array[]::text[],
   array[]::text[],
   '[{"key":"threshold_cents","kind":"currency","label_es":"Umbral en MXN","placeholder":"50000","min":1,"max":100000000000,"defaultValue":5000000}]'::jsonb,
   210)
on conflict (id) do update set
  label_es = excluded.label_es,
  summary_es = excluded.summary_es,
  icon = excluded.icon,
  valid_scopes = excluded.valid_scopes,
  valid_resource_types = excluded.valid_resource_types,
  config_fields = excluded.config_fields,
  sort_order = excluded.sort_order;

-- =============================================================================
-- 3. Consequence shapes
-- =============================================================================

insert into public.rule_shapes (
  id, kind, label_es, summary_es, icon,
  valid_scopes, valid_resource_types, config_fields, sort_order
) values
  ('requireApproval',
   'consequence',
   'Requerir aprobación de un admin',
   'Crea una acción pendiente en la bandeja de los admins del grupo para que aprueben o rechacen.',
   'checkmark.shield',
   array[]::text[],
   array[]::text[],
   '[]'::jsonb,
   100),
  ('lockBookings',
   'consequence',
   'Bloquear nuevos bookings del activo',
   'Marca el activo para que el grupo no acepte más reservas hasta que se desbloquee. Idempotente: si ya está bloqueado, no duplica.',
   'lock.fill',
   array[]::text[],
   array['asset']::text[],
   '[]'::jsonb,
   110)
on conflict (id) do update set
  label_es = excluded.label_es,
  summary_es = excluded.summary_es,
  icon = excluded.icon,
  valid_scopes = excluded.valid_scopes,
  valid_resource_types = excluded.valid_resource_types,
  config_fields = excluded.config_fields,
  sort_order = excluded.sort_order;

comment on table public.rule_shapes is
  'Catalog of rule shape pieces (triggers/conditions/consequences). Mig 00226 added 4 asset triggers + 2 asset conditions + 2 asset consequences (Plans/Active/AssetRules.md §3). Read via list_rule_shapes() RPC; the iOS Rule Builder renders each row as a chip in the form.';
