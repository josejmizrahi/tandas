-- Mig 00192: Capability lifecycle atoms — Layer 5
--
-- Three new event_types track user-driven changes to capabilities:
--   capabilityToggled            — admin enable/disable a capability on a resource
--   capabilityConfigUpdated      — admin edits config jsonb
--   memberCapabilityOverridden   — new member-level override (Isaac excluded etc.)
--
-- Auto-seeded capability rows (the insert path from
-- `resources_seed_event_caps_after_insert`) are NOT atom'd here — they're
-- noise (12+ caps per event create). We only emit on UPDATEs (user
-- changed state) and on member-override INSERTs (always user-driven).

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog
as $$
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
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden'
  ]);
$$;

-- Trigger 1: capabilityToggled (resource_capabilities.enabled changed)
create or replace function public.handle_capability_toggled()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_group_id     uuid;
  v_resource_type text;
begin
  if new.enabled is distinct from old.enabled then
    select group_id, resource_type into v_group_id, v_resource_type
      from public.resources
     where id = new.resource_id;

    insert into public.system_events (group_id, event_type, resource_id, payload)
    values (
      v_group_id,
      'capabilityToggled',
      new.resource_id,
      jsonb_build_object(
        'capability_block_id', new.capability_block_id,
        'new_enabled',         new.enabled,
        'resource_type',       v_resource_type,
        'changed_by',          auth.uid()
      )
    );
  end if;
  return new;
end;
$$;
revoke execute on function public.handle_capability_toggled() from public, anon, authenticated;

drop trigger if exists on_capability_toggled on public.resource_capabilities;
create trigger on_capability_toggled
  after update of enabled on public.resource_capabilities
  for each row execute function public.handle_capability_toggled();

-- Trigger 2: capabilityConfigUpdated (resource_capabilities.config changed)
create or replace function public.handle_capability_config_updated()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_group_id      uuid;
  v_resource_type text;
begin
  if new.config is distinct from old.config then
    select group_id, resource_type into v_group_id, v_resource_type
      from public.resources
     where id = new.resource_id;

    insert into public.system_events (group_id, event_type, resource_id, payload)
    values (
      v_group_id,
      'capabilityConfigUpdated',
      new.resource_id,
      jsonb_build_object(
        'capability_block_id', new.capability_block_id,
        'resource_type',       v_resource_type,
        'changed_by',          auth.uid()
      )
    );
  end if;
  return new;
end;
$$;
revoke execute on function public.handle_capability_config_updated() from public, anon, authenticated;

drop trigger if exists on_capability_config_updated on public.resource_capabilities;
create trigger on_capability_config_updated
  after update of config on public.resource_capabilities
  for each row execute function public.handle_capability_config_updated();

-- Trigger 3: memberCapabilityOverridden (new override row)
create or replace function public.handle_member_capability_overridden()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.system_events (group_id, event_type, payload)
  values (
    new.group_id,
    'memberCapabilityOverridden',
    jsonb_build_object(
      'override_id',     new.id,
      'member_id',       new.member_id,
      'capability',      new.capability,
      'override_value',  new.override,
      'effective_from',  new.effective_from,
      'effective_until', new.effective_until,
      'created_by',      new.created_by,
      'reason',          new.reason
    )
  );
  return new;
end;
$$;
revoke execute on function public.handle_member_capability_overridden() from public, anon, authenticated;

drop trigger if exists on_member_capability_overridden on public.member_capability_overrides;
create trigger on_member_capability_overridden
  after insert on public.member_capability_overrides
  for each row execute function public.handle_member_capability_overridden();
