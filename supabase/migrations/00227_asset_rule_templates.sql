-- Mig 00227 — Asset rule templates (Plans/Active/AssetRules.md §1 + §7)
--
-- Seeds the 5 canonical asset rule templates the Asset.md §18 spec
-- promised. Each composes the new shape pieces from mig 00226 with
-- existing reusable pieces (`alwaysTrue`, `fine`, `startVote`,
-- `emitWarning`).
--
-- Constraint extension
-- ====================
-- `rule_templates_category_check` (from rule_versions_evaluations_templates
-- mig) originally allowed: attendance|money|allocation|governance|custody
-- |other. AssetRules.md spec'd `assets` as a distinct gallery category
-- so asset-shaped templates cluster together in the UI without bleeding
-- into the broader `custody` bucket (which may host right/space-shaped
-- custody concepts later). The mig drops + re-adds the constraint with
-- `assets` appended before inserting the new rows.
--
-- Templates:
--
--   damage_approval_required       damageReported + damageAmountAbove + requireApproval
--   not_returned_fine              checkoutOverdue + alwaysTrue + fine
--   maintenance_overdue_lock       maintenanceOverdue + alwaysTrue + lockBookings
--   transfer_large_vote            assetTransferred + transferAmountAbove + startVote
--   damage_logged_warning          damageReported + alwaysTrue + emitWarning
--
-- Each `required_capabilities` array gates the template's visibility in
-- the gallery to assets that have those capabilities enabled (the iOS
-- Rule Builder filters client-side so a fund or event never sees an
-- asset template offered).

alter table public.rule_templates
  drop constraint rule_templates_category_check;

alter table public.rule_templates
  add constraint rule_templates_category_check
    check (category = any (array[
      'attendance'::text,
      'money'::text,
      'allocation'::text,
      'governance'::text,
      'custody'::text,
      'assets'::text,
      'other'::text
    ]));

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order
) values
  (
    'damage_approval_required',
    'Daño grande requiere aprobación',
    'Si alguien reporta un daño con costo estimado mayor a $X, se crea una acción pendiente para que un admin apruebe el siguiente paso.',
    'assets',
    'governance',
    array['maintenance']::text[],
    jsonb_build_object('threshold_cents', 500000),
    jsonb_build_object(
      'trigger_shape_id',      'damageReported',
      'condition_shape_ids',   jsonb_build_array('damageAmountAbove'),
      'consequence_shape_ids', jsonb_build_array('requireApproval'),
      'scope_hint',            'resource'
    ),
    'active',
    80
  ),
  (
    'not_returned_fine',
    'Multa por no devolver el activo',
    'Si quien hizo checkout no devuelve el activo después de la fecha esperada (con X días de tolerancia), cobra una multa.',
    'assets',
    'penalty',
    array['custody']::text[],
    jsonb_build_object('grace_days', 1, 'amount', 200),
    jsonb_build_object(
      'trigger_shape_id',      'checkoutOverdue',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('fine'),
      'scope_hint',            'resource'
    ),
    'active',
    90
  ),
  (
    'maintenance_overdue_lock',
    'Bloquea bookings si el mantenimiento está atrasado',
    'Si un mantenimiento queda abierto más de X días, bloquea nuevos bookings del activo hasta que el mantenimiento se cierre o se desbloquee manualmente.',
    'assets',
    'governance',
    array['maintenance','booking']::text[],
    jsonb_build_object('days', 7),
    jsonb_build_object(
      'trigger_shape_id',      'maintenanceOverdue',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('lockBookings'),
      'scope_hint',            'resource'
    ),
    'active',
    100
  ),
  (
    'transfer_large_vote',
    'Voto para transferencias grandes',
    'Si la última valuación del activo supera $X y se intenta transferir, abre automáticamente una votación al grupo.',
    'assets',
    'governance',
    array['transfer','voting']::text[],
    jsonb_build_object(
      'threshold_cents',   5000000,
      'duration_hours',    48,
      'quorum_percent',    50,
      'threshold_percent', 66
    ),
    jsonb_build_object(
      'trigger_shape_id',      'assetTransferred',
      'condition_shape_ids',   jsonb_build_array('transferAmountAbove'),
      'consequence_shape_ids', jsonb_build_array('startVote'),
      'scope_hint',            'resource'
    ),
    'active',
    110
  ),
  (
    'damage_logged_warning',
    'Aviso al grupo cuando se reporta un daño',
    'Cualquier daño reportado emite un aviso visible en la actividad del grupo. Útil para que los admins vean reportes sin esperar a que se acumulen.',
    'assets',
    'governance',
    array['maintenance']::text[],
    jsonb_build_object(),
    jsonb_build_object(
      'trigger_shape_id',      'damageReported',
      'condition_shape_ids',   jsonb_build_array('alwaysTrue'),
      'consequence_shape_ids', jsonb_build_array('emitWarning'),
      'scope_hint',            'resource'
    ),
    'active',
    120
  )
on conflict (id) do update set
  display_name_es       = excluded.display_name_es,
  description_es        = excluded.description_es,
  category              = excluded.category,
  template_kind         = excluded.template_kind,
  required_capabilities = excluded.required_capabilities,
  default_params        = excluded.default_params,
  composition           = excluded.composition,
  status                = excluded.status,
  sort_order            = excluded.sort_order;

comment on table public.rule_templates is
  'Curated rule template catalog. Mig 00227 added the 5 canonical asset templates under category=assets (Plans/Active/AssetRules.md §1) + extended rule_templates_category_check to include assets. Read via list_rule_templates() RPC. iOS mirror lives in MockRuleTemplateRepository.defaultBetaCatalog for previews + offline.';
