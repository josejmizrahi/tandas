-- Mig 00210: `eventUpdated` atom for non-title event metadata changes
--
-- Plans/Active/EventResource.md §8 lists `eventUpdated` as a canonical
-- lifecycle atom. Today, `update_event_metadata` (mig 00159) mutates
-- `resources.metadata` directly without emitting any atom for non-title
-- changes:
--   - Title change → `handle_resource_renamed` (mig 00186) emits
--     `resourceRenamed` ✓
--   - Location / starts_at / duration / host_id / description / cover →
--     silent ✗ (no audit trail per §17)
--
-- This migration adds a trigger that emits `eventUpdated` when an event
-- resource's metadata changes in any way OTHER than title (renames keep
-- emitting `resourceRenamed`, not eventUpdated — they are semantically
-- distinct atoms per spec §8).
--
-- Payload carries the set of changed top-level metadata keys so consumers
-- can react narrowly without re-fetching. Use jsonb key diff (old.metadata
-- ?| new.metadata not direct; we do a per-key comparison via a CTE-style
-- subquery in the trigger body for clarity + performance).

-- =========================================================
-- 1. Whitelist update — add eventUpdated
-- =========================================================

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable parallel safe
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
    'fundCreated', 'fundDeposit', 'fundThresholdReached', 'fundLocked', 'fundUnlocked',
    'positionChanged', 'memberJoined', 'memberLeft',
    'ruleEnabledChanged', 'ruleAmountChanged',
    'pendingChangeApplied', 'inviteCodeRotated',
    'groupCreated', 'groupArchived', 'groupUnarchived', 'groupRenamed', 'governanceUpdated',
    'resourceArchived', 'resourceUnarchived', 'resourceRenamed',
    'capabilityToggled', 'capabilityConfigUpdated', 'memberCapabilityOverridden',
    'ledgerEntryCreated', 'warningEmitted',
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored',
    'rightExpiringSoon',
    'assetTransferred', 'assetAssigned', 'assetReturned',
    'custodyAssigned', 'custodyReleased',
    'maintenanceLogged', 'maintenanceCompleted', 'damageReported',
    'assetUsed', 'assetCheckedOut', 'assetCheckedIn',
    'valuationRecorded',
    'resourceLinked', 'resourceUnlinked',
    'eventCancelled',
    'eventStarted',
    -- mig 00210: non-title event metadata mutation atom
    'eventUpdated'
  ]);
$$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist of system_events.event_type values. v_post_reconcile_4 (00210): adds eventUpdated.';

-- =========================================================
-- 2. Trigger: emit eventUpdated for non-title metadata mutations
-- =========================================================

create or replace function public.handle_event_metadata_updated()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_changed_keys text[];
  v_old_title text;
  v_new_title text;
begin
  -- Only events. Other resource_types have their own lifecycle atoms.
  if new.resource_type <> 'event' then
    return new;
  end if;

  -- No change → no atom (defensive; the WHEN clause below already gates this).
  if new.metadata is not distinct from old.metadata then
    return new;
  end if;

  -- Compute the changed top-level keys (jsonb @ jsonb diff). We compare
  -- per-key by serializing values; SQL doesn't have a built-in jsonb diff
  -- so we build the set manually from the union of keys.
  select array_agg(distinct k order by k)
    into v_changed_keys
    from (
      select jsonb_object_keys(new.metadata) as k
      union
      select jsonb_object_keys(old.metadata) as k
    ) keys
   where new.metadata->>k is distinct from old.metadata->>k;

  v_old_title := old.metadata->>'title';
  v_new_title := new.metadata->>'title';

  -- If title changed and nothing else did, leave the rename atom alone —
  -- `handle_resource_renamed` (mig 00186) is the canonical emitter for
  -- that case. We only emit `eventUpdated` when at least one non-title
  -- key changed.
  if v_changed_keys is null or v_changed_keys = array['title']::text[] then
    return new;
  end if;

  insert into public.system_events (group_id, event_type, resource_id, payload)
  values (
    new.group_id,
    'eventUpdated',
    new.id,
    jsonb_build_object(
      'changed_keys',  to_jsonb(v_changed_keys),
      'changed_by',    auth.uid(),
      'title',         v_new_title,
      'title_changed', v_new_title is distinct from v_old_title
    )
  );

  return new;
end;
$$;
revoke execute on function public.handle_event_metadata_updated() from public, anon, authenticated;

drop trigger if exists on_event_metadata_updated on public.resources;
create trigger on_event_metadata_updated
  after update of metadata on public.resources
  for each row
  when (new.resource_type = 'event' and new.metadata is distinct from old.metadata)
  execute function public.handle_event_metadata_updated();

comment on function public.handle_event_metadata_updated() is
  'Emits eventUpdated atom when an event resource''s metadata mutates in any way other than (only) title. Title-only renames stay with resourceRenamed (mig 00186). Plans/Active/EventResource.md §8 + §17.';
