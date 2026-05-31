-- Mig 00193: expense_threshold_warning pilot — first non-attendance rule template.
--
-- Beta 1 Builder shipped attendance + fine variants only. This pilot proves
-- the engine + Builder support Money/Governance verticals by adding the
-- smallest end-to-end slice that reacts to a ledger entry being recorded:
--
--   "When a ledger entry is created and its amount > threshold, emit a
--    warning to the group's activity feed."
--
-- Vote-retro / refund workflow is deferred (Beta 2). For now `emitWarning`
-- gives admins visibility on big movements without committing to vote
-- semantics.
--
-- Adds:
--   1. SystemEventType whitelist: ledgerEntryCreated + warningEmitted.
--   2. Trigger on ledger_entries insert → emits ledgerEntryCreated atom.
--   3. 3 shape pieces in public.rule_shapes (trigger + condition + consequence).
--   4. 1 template in public.rule_templates: expense_threshold_warning.
--
-- TS evaluators land in supabase/functions/_shared/ruleEngine.ts in the
-- same PR (mig is data, evaluator is code — both required for end-to-end).

-- =============================================================================
-- 1. Extend SystemEventType whitelist
-- =============================================================================

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
    -- mig 00193: expense_threshold_warning pilot
    'ledgerEntryCreated', 'warningEmitted'
  ]);
$function$;

-- =============================================================================
-- 2. Trigger on ledger_entries insert → emit ledgerEntryCreated atom
-- =============================================================================

create or replace function public.ledger_entries_emit_atom()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_member_id uuid;
begin
  -- Resolve the member_id (from group_members) for the recorder so the
  -- rule engine's trigger evaluator has a target without a re-fetch.
  -- `recorded_by` is auth.users.id; we need group_members.id.
  select gm.id into v_member_id
  from public.group_members gm
  where gm.group_id = NEW.group_id
    and gm.user_id  = NEW.recorded_by
  limit 1;

  perform public.record_system_event(
    p_group_id    => NEW.group_id,
    p_event_type  => 'ledgerEntryCreated',
    p_resource_id => NEW.resource_id,
    p_member_id   => v_member_id,
    p_payload     => jsonb_build_object(
      'ledger_entry_id', NEW.id,
      'type',            NEW.type,
      'amount_cents',    NEW.amount_cents,
      'currency',        NEW.currency,
      'from_member_id',  NEW.from_member_id,
      'to_member_id',    NEW.to_member_id,
      'recorded_by',     NEW.recorded_by
    )
  );

  return NEW;
end;
$function$;

drop trigger if exists ledger_entries_emit_atom_trg on public.ledger_entries;

create trigger ledger_entries_emit_atom_trg
  after insert on public.ledger_entries
  for each row execute function public.ledger_entries_emit_atom();

comment on function public.ledger_entries_emit_atom() is
  'Emits ledgerEntryCreated system_event atom for every new ledger row so the rule engine can react. Resolves the recorder''s group_members.id so the trigger evaluator has a target without a re-fetch. Per mig 00193 (expense_threshold_warning pilot).';

-- =============================================================================
-- 3. Shape pieces (Builder catalog)
-- =============================================================================

insert into public.rule_shapes (id, kind, label_es, summary_es, icon, valid_scopes, valid_resource_types, sort_order)
values
  (
    'ledgerEntryCreated',
    'trigger',
    'Cuando se registra un movimiento de dinero',
    'Se dispara cada vez que alguien registra un gasto, aporte, transferencia o cualquier entrada en el libro mayor del grupo.',
    'dollarsign.circle',
    array['group','resource']::text[],
    array['fund','event']::text[],
    60
  ),
  (
    'amountAbove',
    'condition',
    'Solo si el monto supera $X',
    'Filtra para que la regla aplique únicamente cuando el monto del movimiento supere el umbral configurado.',
    null,
    array[]::text[],
    array[]::text[],
    30
  ),
  (
    'emitWarning',
    'consequence',
    'Emitir un aviso al grupo',
    'Anota un aviso en la actividad del grupo. Los administradores lo ven; no se cobra dinero ni se abre voto.',
    'exclamationmark.triangle',
    array[]::text[],
    array[]::text[],
    20
  );

-- =============================================================================
-- 4. Template (Builder gallery)
-- =============================================================================

insert into public.rule_templates (id, display_name_es, description_es, category, template_kind, required_capabilities, default_params, composition, status, sort_order)
values (
  'expense_threshold_warning',
  'Aviso por gasto grande',
  'Cuando alguien registre un movimiento de dinero mayor a X pesos, el grupo recibe un aviso en la actividad. Útil para que los administradores vean gastos grandes sin tener que pedir aprobación previa.',
  'money',
  'governance',
  array['ledger']::text[],
  jsonb_build_object('threshold_cents', 200000),
  jsonb_build_object(
    'trigger_shape_id',      'ledgerEntryCreated',
    'condition_shape_ids',   jsonb_build_array('amountAbove'),
    'consequence_shape_ids', jsonb_build_array('emitWarning'),
    'scope_hint',            'group'
  ),
  'active',
  60
);
