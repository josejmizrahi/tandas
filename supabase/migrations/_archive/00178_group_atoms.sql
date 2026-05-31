-- Mig 00178: Group atoms — Layer 1 lifecycle events into system_events
--
-- Constitution Layer 1 (Subject/Domain) had no atom trail. Group create /
-- archive / rename / governance edit all happened silently. This wires
-- triggers on `public.groups` that emit into `system_events`, the
-- group-scoped atom table — same pattern as resource lifecycle events.
--
-- Five new event_types: groupCreated, groupArchived, groupUnarchived,
-- groupRenamed, governanceUpdated. Whitelist updated to match the Swift
-- enum (codegen mirrors `_shared/types/systemEventType.ts`).

-- 1) Whitelist update
create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
immutable
parallel safe
as $$
  -- Keep this list in sync with
  -- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/SystemEventType.swift
  -- (and the codegen mirror in supabase/functions/_shared/types/systemEventType.ts).
  -- Adding a new case in Swift requires regenerating the TS catalog and
  -- shipping a new migration to update this function.
  select p_event_type = any (array[
    'eventClosed',
    'eventCreated',
    'rsvpDeadlinePassed',
    'hoursBeforeEvent',
    'rsvpSubmitted',
    'rsvpChangedSameDay',
    'checkInRecorded',
    'checkInMissed',
    'eventDescriptionMissing',
    'slotAssigned',
    'slotDeclined',
    'slotExpired',
    'slotSwapRequested',
    'slotSwapApproved',
    'bookingCreated',
    'bookingCancelled',
    'bookingExpired',
    'assetCreated',
    'fineOfficialized',
    'fineVoided',
    'finePaid',
    'fineReminderSent',
    'appealCreated',
    'appealResolved',
    'voteOpened',
    'voteCast',
    'voteResolved',
    'fundCreated',
    'fundDeposit',
    'fundThresholdReached',
    'positionChanged',
    'memberJoined',
    'memberLeft',
    'ruleEnabledChanged',
    'ruleAmountChanged',
    'pendingChangeApplied',
    'inviteCodeRotated',
    'groupCreated',
    'groupArchived',
    'groupUnarchived',
    'groupRenamed',
    'governanceUpdated'
  ]);
$$;

-- 2) groupCreated — after insert on groups
create or replace function public.handle_group_created()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- member_id is null because the founder's group_members row may not
  -- exist yet at this exact moment (create_group_with_admin inserts the
  -- group first, the membership row second). Payload carries created_by
  -- so the audit knows who triggered it.
  insert into public.system_events (group_id, event_type, payload)
  values (
    new.id,
    'groupCreated',
    jsonb_build_object(
      'created_by',    new.created_by,
      'base_template', new.base_template,
      'category',      new.category
    )
  );
  return new;
end;
$$;
revoke execute on function public.handle_group_created() from public, anon, authenticated;

drop trigger if exists on_group_created on public.groups;
create trigger on_group_created
  after insert on public.groups
  for each row execute function public.handle_group_created();

-- 3) groupArchived / groupUnarchived — after update of archived_at
create or replace function public.handle_group_archive_toggle()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.archived_at is null and new.archived_at is not null then
    insert into public.system_events (group_id, event_type, payload)
    values (
      new.id,
      'groupArchived',
      jsonb_build_object('archived_by', new.archived_by)
    );
  elsif old.archived_at is not null and new.archived_at is null then
    insert into public.system_events (group_id, event_type, payload)
    values (
      new.id,
      'groupUnarchived',
      jsonb_build_object('restored_by', auth.uid())
    );
  end if;
  return new;
end;
$$;
revoke execute on function public.handle_group_archive_toggle() from public, anon, authenticated;

drop trigger if exists on_group_archive_toggle on public.groups;
create trigger on_group_archive_toggle
  after update of archived_at on public.groups
  for each row execute function public.handle_group_archive_toggle();

-- 4) groupRenamed — after update of name
create or replace function public.handle_group_renamed()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.name is distinct from old.name then
    insert into public.system_events (group_id, event_type, payload)
    values (
      new.id,
      'groupRenamed',
      jsonb_build_object(
        'old_name',   old.name,
        'new_name',   new.name,
        'changed_by', auth.uid()
      )
    );
  end if;
  return new;
end;
$$;
revoke execute on function public.handle_group_renamed() from public, anon, authenticated;

drop trigger if exists on_group_renamed on public.groups;
create trigger on_group_renamed
  after update of name on public.groups
  for each row execute function public.handle_group_renamed();

-- 5) governanceUpdated — after update of governance
create or replace function public.handle_governance_updated()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.governance is distinct from old.governance then
    -- We intentionally do NOT snapshot the full governance jsonb in the
    -- payload — it can be large and the audit trail can recover the old
    -- state via system_events.occurred_at + a temporal query if ever
    -- needed. Carry only the keys that changed for fast triage.
    insert into public.system_events (group_id, event_type, payload)
    values (
      new.id,
      'governanceUpdated',
      jsonb_build_object(
        'changed_by', auth.uid(),
        'old_keys',   coalesce((select jsonb_agg(k order by k) from jsonb_object_keys(old.governance) k), '[]'::jsonb),
        'new_keys',   coalesce((select jsonb_agg(k order by k) from jsonb_object_keys(new.governance) k), '[]'::jsonb)
      )
    );
  end if;
  return new;
end;
$$;
revoke execute on function public.handle_governance_updated() from public, anon, authenticated;

drop trigger if exists on_governance_updated on public.groups;
create trigger on_governance_updated
  after update of governance on public.groups
  for each row execute function public.handle_governance_updated();
