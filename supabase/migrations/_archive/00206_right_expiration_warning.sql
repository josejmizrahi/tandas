-- Mig 00203: right_expiration_warning — first rule template anchored
-- on right.* atoms.
--
-- Why
-- ===
-- Mig 00198+00199 shipped the right lifecycle: 8 atoms, 6 RPCs, and
-- the `expire-due-rights-every-hour` cron flips active rights to
-- `expired` once their `expires_at` lapses. But there's no
-- pre-warning: a holder finds out their right vanished only when
-- they try to use it. Rule template `right_expiration_warning` closes
-- that gap as the first canonical rule reacting to a right.* event,
-- and is the smoke test proving the engine + atoms + cron compose
-- end-to-end for the right resource_type.
--
-- Engine path:
--   notify_rights_expiring_soon() (cron, daily noon)
--     → emits `rightExpiringSoon` atom for each right entering the
--       N-day window (idempotent via metadata.expiration_warning_emitted)
--   process-system-events
--     → trigger evaluator for `rightExpiringSoon` (added in ruleEngine.ts
--       same PR) hands the right's holder + days_until_expiry as the
--       rule target
--     → `daysBeforeExpiry` condition evaluator gates by configured threshold
--     → `emitWarning` consequence fires (existing executor from mig 00193)
--
-- Adds:
--   1. SystemEventType whitelist: `rightExpiringSoon`.
--   2. `notify_rights_expiring_soon(p_days int)` SECURITY DEFINER fn +
--      pg_cron daily job at 12:07.
--   3. 3 shape pieces (trigger + condition + consequence reuse).
--   4. 1 rule_templates row (`right_expiration_warning`).
--
-- Idempotency
-- ===========
-- The cron sets `metadata.expiration_warning_emitted = true` on the
-- right's row the first time it lands in the warning window. Future
-- runs skip rights that already carry the flag. A revoke + restore +
-- new expires_at would need an admin to clear the flag manually via
-- update_right_metadata — by design: a single emission is what a
-- single rule template "fire once" expects.

BEGIN;

-- ============================================================================
-- 1. SystemEventType whitelist — add `rightExpiringSoon`
-- ============================================================================

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
set search_path = pg_catalog
as $function$
  select p_event_type = any (array[
    'eventClosed', 'eventCreated', 'rsvpDeadlinePassed', 'hoursBeforeEvent',
    'rsvpSubmitted', 'rsvpChangedSameDay', 'checkInRecorded', 'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned', 'slotDeclined', 'slotExpired', 'slotSwapRequested', 'slotSwapApproved',
    'bookingCreated', 'bookingCancelled', 'bookingExpired',
    'assetCreated',
    'fineOfficialized', 'fineVoided', 'finePaid', 'fineReminderSent',
    'appealCreated', 'appealResolved',
    'voteOpened', 'voteCast', 'voteResolved',
    'fundCreated', 'fundDeposit', 'fundThresholdReached',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    -- mig 00203: pre-expiry warning atom for rule template.
    'rightExpiringSoon'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. v9 (00203): + rightExpiringSoon.';

-- ============================================================================
-- 2. notify_rights_expiring_soon() + cron
-- ============================================================================
--
-- Scans active rights with `metadata.expires_at` in (now, now + p_days_window
-- days) AND not yet flagged with `metadata.expiration_warning_emitted`.
-- Emits one `rightExpiringSoon` atom per match with the days-remaining
-- pre-computed in the payload (saves the trigger evaluator a re-fetch).
-- The flag is set atomically alongside the atom insert so a second run
-- within the same day is a no-op.
--
-- p_days_window defaults to 14 — generous so members have time to act
-- (transfer, renew via update_right_metadata, etc.). Rule template
-- bounds the actual "alert" threshold via `daysBeforeExpiry` condition.

create or replace function public.notify_rights_expiring_soon(
  p_days_window int default 14
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count       int := 0;
  v_row         record;
  v_days_left   int;
begin
  if p_days_window is null or p_days_window <= 0 then
    raise exception 'p_days_window must be positive' using errcode = '22023';
  end if;

  for v_row in
    select
      r.id,
      r.group_id,
      r.metadata,
      (r.metadata->>'holder_member_id')::uuid as holder_member_id,
      nullif(r.metadata->>'expires_at','')::timestamptz as expires_at
      from public.resources r
     where r.resource_type = 'right'
       and r.status = 'active'
       and r.archived_at is null
       and r.metadata ? 'expires_at'
       and nullif(r.metadata->>'expires_at','')::timestamptz is not null
       and nullif(r.metadata->>'expires_at','')::timestamptz > now()
       and nullif(r.metadata->>'expires_at','')::timestamptz
             <= now() + make_interval(days => p_days_window)
       and coalesce((r.metadata->>'expiration_warning_emitted')::boolean, false) = false
     for update skip locked
  loop
    v_days_left := greatest(
      0,
      extract(day from v_row.expires_at - now())::int
    );

    update public.resources
       set metadata = metadata || jsonb_build_object(
         'expiration_warning_emitted', true,
         'expiration_warning_emitted_at', now()
       )
     where id = v_row.id
       and coalesce((metadata->>'expiration_warning_emitted')::boolean, false) = false;

    -- If the conditional UPDATE didn't fire (race with another cron run
    -- on the same row), skip the atom emit too — keep idempotency tight.
    if not found then
      continue;
    end if;

    perform public.record_system_event(
      v_row.group_id,
      'rightExpiringSoon',
      v_row.id,
      v_row.holder_member_id,
      jsonb_build_object(
        'expires_at',         v_row.expires_at,
        'holder_member_id',   v_row.holder_member_id,
        'name',               v_row.metadata->>'name',
        'days_until_expiry',  v_days_left,
        'window_days',        p_days_window,
        'source',             'cron:notify_rights_expiring_soon'
      )
    );

    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    raise notice 'notify_rights_expiring_soon: emitted % warning(s)', v_count;
  end if;

  return v_count;
end;
$$;

revoke execute on function public.notify_rights_expiring_soon(int) from public, anon, authenticated;
grant  execute on function public.notify_rights_expiring_soon(int) to service_role;

comment on function public.notify_rights_expiring_soon(int) is
  'Cron-driven: emits rightExpiringSoon for active rights entering the warning window (default 14 days). Sets metadata.expiration_warning_emitted to deduplicate. Mig 00203.';

select cron.schedule(
  'notify-rights-expiring-soon-daily',
  '7 12 * * *',  -- 12:07 daily, off the busy :00 slot
  $$ select public.notify_rights_expiring_soon(14); $$
);

-- ============================================================================
-- 3. rule_shapes — trigger + condition (consequence `emitWarning` already
--    exists via mig 00193)
-- ============================================================================

insert into public.rule_shapes (
  id, kind, label_es, summary_es, icon, valid_scopes, valid_resource_types, sort_order
) values
  (
    'rightExpiringSoon',
    'trigger',
    'Cuando un derecho está por vencer',
    'Se dispara una vez por cada derecho activo que entra en la ventana previa al vencimiento (default 14 días).',
    'hourglass',
    array['group','resource']::text[],
    array['right']::text[],
    70
  ),
  (
    'daysBeforeExpiry',
    'condition',
    'Cuando faltan ≤ N días',
    'Filtra para que la regla aplique sólo cuando los días restantes hasta el vencimiento sean menores o iguales al umbral configurado.',
    null,
    array[]::text[],
    array[]::text[],
    40
  )
on conflict (id) do update set
  kind                  = excluded.kind,
  label_es              = excluded.label_es,
  summary_es            = excluded.summary_es,
  icon                  = excluded.icon,
  valid_scopes          = excluded.valid_scopes,
  valid_resource_types  = excluded.valid_resource_types,
  sort_order            = excluded.sort_order;

-- ============================================================================
-- 4. rule_templates — right_expiration_warning
-- ============================================================================

insert into public.rule_templates (
  id, display_name_es, description_es, category, template_kind,
  required_capabilities, default_params, composition, status, sort_order
) values (
  'right_expiration_warning',
  'Aviso antes de que venza un derecho',
  'Cuando un derecho está por vencer (default: 7 días antes), el grupo recibe un aviso en la actividad para que el titular pueda transferirlo, renovarlo o ejercerlo a tiempo.',
  'custody',
  'governance',
  array[]::text[],
  jsonb_build_object('days_before', 7),
  jsonb_build_object(
    'trigger_shape_id',      'rightExpiringSoon',
    'condition_shape_ids',   jsonb_build_array('daysBeforeExpiry'),
    'consequence_shape_ids', jsonb_build_array('emitWarning'),
    'scope_hint',            'group'
  ),
  'active',
  70
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
  sort_order            = excluded.sort_order,
  updated_at            = now();

COMMIT;
