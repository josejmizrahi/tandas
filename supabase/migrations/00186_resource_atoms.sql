-- Mig 00186: Resource lifecycle atoms — Layer 3
--
-- Mirrors mig 00178 (group atoms) for Layer 3. Three new event_types:
--   resourceArchived   — archived_at null → set
--   resourceUnarchived — archived_at set → null
--   resourceRenamed    — metadata->>'title' or ->>'name' changed
--
-- Creation atoms already exist per resource_type (eventCreated, assetCreated,
-- fundCreated). We only add the LIFECYCLE atoms that are generic across
-- types.
--
-- Triggers run AFTER UPDATE on public.resources, gated by which columns
-- changed. We insert directly into system_events (SECURITY DEFINER bypasses
-- the atom guard's INSERT path, which is allowed).

-- 1) Whitelist update
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
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed'
  ]);
$$;

-- 2) Archive toggle trigger
create or replace function public.handle_resource_archive_toggle()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.archived_at is null and new.archived_at is not null then
    insert into public.system_events (group_id, event_type, resource_id, payload)
    values (
      new.group_id,
      'resourceArchived',
      new.id,
      jsonb_build_object(
        'archived_by',   new.archived_by,
        'resource_type', new.resource_type
      )
    );
  elsif old.archived_at is not null and new.archived_at is null then
    insert into public.system_events (group_id, event_type, resource_id, payload)
    values (
      new.group_id,
      'resourceUnarchived',
      new.id,
      jsonb_build_object(
        'restored_by',   auth.uid(),
        'resource_type', new.resource_type
      )
    );
  end if;
  return new;
end;
$$;
revoke execute on function public.handle_resource_archive_toggle() from public, anon, authenticated;

drop trigger if exists on_resource_archive_toggle on public.resources;
create trigger on_resource_archive_toggle
  after update of archived_at on public.resources
  for each row execute function public.handle_resource_archive_toggle();

-- 3) Rename trigger — metadata.title (event) or metadata.name (asset/fund/etc.)
create or replace function public.handle_resource_renamed()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old_label text;
  v_new_label text;
begin
  -- "title" wins for events; "name" wins for non-events. Take whichever is
  -- present on the new row and compare to the same key on the old row.
  v_old_label := coalesce(old.metadata->>'title', old.metadata->>'name');
  v_new_label := coalesce(new.metadata->>'title', new.metadata->>'name');

  if v_new_label is distinct from v_old_label then
    insert into public.system_events (group_id, event_type, resource_id, payload)
    values (
      new.group_id,
      'resourceRenamed',
      new.id,
      jsonb_build_object(
        'old_label',     v_old_label,
        'new_label',     v_new_label,
        'resource_type', new.resource_type,
        'changed_by',    auth.uid()
      )
    );
  end if;
  return new;
end;
$$;
revoke execute on function public.handle_resource_renamed() from public, anon, authenticated;

drop trigger if exists on_resource_renamed on public.resources;
create trigger on_resource_renamed
  after update of metadata on public.resources
  for each row execute function public.handle_resource_renamed();
