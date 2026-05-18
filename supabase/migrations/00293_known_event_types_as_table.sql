-- 00293 — Migrate is_known_system_event_type whitelist from a function
-- body array to a table-backed, additive-only catalog.
--
-- Plans/Active/RolesRemediation_2026-05-17.md Sprint F (urgent doctrinal).
--
-- Problem
-- =======
-- The whitelist lives in the body of `is_known_system_event_type(text)`
-- as a literal text[] array. Every modification CREATEs OR REPLACEs
-- the whole function, which requires every migration author to start
-- from a fresh pg_dump of the live body and emit the FULL UNION. This
-- convention has failed twice in <24h (mig 00285 + 00288 + 00292 all
-- lost groupRolesChanged to parallel branches) — corrupting the
-- contract that record_system_event's NOTICE + the CHECK constraint
-- depend on. Each failure broke production RPCs (upsert_group_role /
-- delete_group_role would partial-state and abort).
--
-- Fix
-- ===
-- Move the whitelist to a `known_event_types` TABLE. Each migration
-- INSERTs its new entry (additive, parallel-safe — Postgres serializes
-- INSERTs and PK conflict is idempotent via ON CONFLICT DO NOTHING).
-- Whoever needs to consult the whitelist queries the table.
--
-- Volatility wrinkle
-- ==================
-- The current CHECK constraint `system_events_event_type_known_chk`
-- depends on the IMMUTABLE function (CHECK constraints in Postgres
-- require IMMUTABLE expressions, and IMMUTABLE functions cannot read
-- from tables). Conversion path:
--   1. Drop the CHECK.
--   2. Add a BEFORE INSERT/UPDATE trigger that validates event_type
--      against the table (STABLE table query is fine in a trigger).
--   3. Keep `is_known_system_event_type(text)` as STABLE table query
--      so existing consumers (record_system_event's NOTICE path,
--      tests, edge fns) keep working.
--
-- Migration convention going forward
-- ==================================
-- New atom types: call `register_event_type('myAtom', 'mig_00XXX', 'notes')`
-- in the migration. Idempotent. NEVER use CREATE OR REPLACE FUNCTION
-- on `is_known_system_event_type` again — comment in the function body
-- reinforces this.

-- =============================================================================
-- 1. Create the table
-- =============================================================================
create table if not exists public.known_event_types (
  event_type        text         not null primary key,
  source_migration  text         not null,
  notes             text,
  registered_at     timestamptz  not null default now()
);

comment on table public.known_event_types is
  'Append-only catalog of system_events.event_type values. Each row records when the atom was introduced and by which migration. Replaces the literal array in is_known_system_event_type(text). Add via register_event_type RPC. See mig 00293 retrospective.';
comment on column public.known_event_types.event_type     is 'Atom identifier. PK. Case-sensitive (matches jsonb).';
comment on column public.known_event_types.source_migration is 'Migration that registered this entry (free text — e.g. "mig_00229" or "mig_00292_v4_reunion").';
comment on column public.known_event_types.notes is 'Optional human-readable purpose.';

-- RLS: read-only to authenticated; writes only via SECURITY DEFINER RPC.
alter table public.known_event_types enable row level security;

drop policy if exists known_event_types_select on public.known_event_types;
create policy known_event_types_select
  on public.known_event_types
  for select
  to authenticated, service_role
  using (true);

-- No insert/update/delete policy — DDL writes only via service_role
-- (used by migrations) or via register_event_type RPC.

-- =============================================================================
-- 2. Backfill from the current function body (live state as of mig 00292)
-- =============================================================================
-- Each entry: (event_type, source_migration, notes).
-- source_migration captures the migration that first added the atom where
-- the trail is known; "pre_00293_backfill" for entries that predate the
-- table-based catalog and don't have an obvious single owner.

insert into public.known_event_types (event_type, source_migration, notes) values
  -- Event lifecycle
  ('eventClosed',                   'pre_00293_backfill', null),
  ('eventCreated',                  'pre_00293_backfill', null),
  ('rsvpDeadlinePassed',            'pre_00293_backfill', null),
  ('hoursBeforeEvent',              'pre_00293_backfill', null),
  ('eventCancelled',                'pre_00293_backfill', null),
  ('eventStarted',                  'pre_00293_backfill', 'mig 00214'),
  ('eventUpdated',                  'pre_00293_backfill', 'mig 00210'),
  -- RSVP / attendance
  ('rsvpSubmitted',                 'pre_00293_backfill', null),
  ('rsvpChangedSameDay',            'pre_00293_backfill', null),
  ('checkInRecorded',               'pre_00293_backfill', null),
  ('checkInMissed',                 'pre_00293_backfill', null),
  ('eventDescriptionMissing',       'pre_00293_backfill', null),
  -- Slot
  ('slotAssigned',                  'pre_00293_backfill', null),
  ('slotDeclined',                  'pre_00293_backfill', null),
  ('slotExpired',                   'pre_00293_backfill', null),
  ('slotSwapRequested',             'pre_00293_backfill', null),
  ('slotSwapApproved',              'pre_00293_backfill', null),
  ('slotCreated',                   'pre_00293_backfill', 'slot_created_released_atoms'),
  ('slotReleased',                  'pre_00293_backfill', 'slot_created_released_atoms'),
  -- Booking
  ('bookingCreated',                'pre_00293_backfill', null),
  ('bookingCancelled',              'pre_00293_backfill', null),
  ('bookingExpired',                'pre_00293_backfill', null),
  ('bookingNoCheckIn',              'mig_00269',          'space_no_check_in_atom'),
  -- Asset
  ('assetCreated',                  'pre_00293_backfill', null),
  ('assetTransferred',              'pre_00293_backfill', null),
  ('assetAssigned',                 'pre_00293_backfill', null),
  ('assetReturned',                 'pre_00293_backfill', null),
  ('custodyAssigned',               'pre_00293_backfill', null),
  ('custodyReleased',               'pre_00293_backfill', null),
  ('maintenanceLogged',             'pre_00293_backfill', null),
  ('maintenanceCompleted',          'pre_00293_backfill', null),
  ('damageReported',                'pre_00293_backfill', null),
  ('assetUsed',                     'pre_00293_backfill', null),
  ('assetCheckedOut',               'pre_00293_backfill', null),
  ('assetCheckedIn',                'pre_00293_backfill', null),
  ('valuationRecorded',             'pre_00293_backfill', null),
  ('assetCheckoutOverdue',          'mig_00225',          'asset_rule_atoms'),
  ('assetMaintenanceOverdue',       'mig_00225',          'asset_rule_atoms'),
  ('assetBookingsLocked',           'pre_00293_backfill', 'asset_booking_lock_atom_rpc'),
  ('assetBookingsUnlocked',         'pre_00293_backfill', 'asset_booking_lock_atom_rpc'),
  -- Fines + appeals + votes
  ('fineOfficialized',              'pre_00293_backfill', null),
  ('fineVoided',                    'pre_00293_backfill', null),
  ('finePaid',                      'pre_00293_backfill', null),
  ('fineReminderSent',              'pre_00293_backfill', null),
  ('appealCreated',                 'pre_00293_backfill', null),
  ('appealResolved',                'pre_00293_backfill', null),
  ('voteOpened',                    'pre_00293_backfill', null),
  ('voteCast',                      'pre_00293_backfill', null),
  ('voteResolved',                  'pre_00293_backfill', null),
  -- Fund
  ('fundCreated',                   'pre_00293_backfill', null),
  ('fundDeposit',                   'pre_00293_backfill', null),
  ('fundThresholdReached',          'pre_00293_backfill', null),
  ('fundLocked',                    'pre_00293_backfill', null),
  ('fundUnlocked',                  'pre_00293_backfill', null),
  -- Space
  ('spaceCreated',                  'mig_00203',          null),
  ('spaceBooked',                   'pre_00293_backfill', 'mig 00207 + 00264'),
  ('spaceReleased',                 'pre_00293_backfill', 'mig 00207 + 00264'),
  ('spaceCapacityReached',          'pre_00293_backfill', 'mig 00207 + 00264'),
  ('spaceWaitlistJoined',           'pre_00293_backfill', 'mig 00207 + 00264'),
  ('spaceWaitlistPromoted',         'pre_00293_backfill', 'mig 00207 + 00264'),
  ('spaceAccessGranted',            'pre_00293_backfill', 'mig 00207 + 00264'),
  ('spaceAccessRevoked',            'pre_00293_backfill', 'mig 00207 + 00264'),
  -- Rotation / membership
  ('positionChanged',               'pre_00293_backfill', null),
  ('memberJoined',                  'pre_00293_backfill', null),
  ('memberLeft',                    'pre_00293_backfill', null),
  -- Rule audit
  ('ruleEnabledChanged',            'pre_00293_backfill', null),
  ('ruleAmountChanged',             'pre_00293_backfill', null),
  -- Governance
  ('pendingChangeApplied',          'pre_00293_backfill', null),
  ('inviteCodeRotated',             'pre_00293_backfill', null),
  -- Group lifecycle
  ('groupCreated',                  'pre_00293_backfill', null),
  ('groupArchived',                 'pre_00293_backfill', null),
  ('groupUnarchived',               'pre_00293_backfill', null),
  ('groupRenamed',                  'pre_00293_backfill', null),
  ('governanceUpdated',             'pre_00293_backfill', null),
  -- Resource lifecycle
  ('resourceArchived',              'pre_00293_backfill', null),
  ('resourceUnarchived',            'pre_00293_backfill', null),
  ('resourceRenamed',               'pre_00293_backfill', null),
  -- Capability lifecycle
  ('capabilityToggled',             'pre_00293_backfill', null),
  ('capabilityConfigUpdated',       'pre_00293_backfill', null),
  ('memberCapabilityOverridden',    'pre_00293_backfill', null),
  ('memberCapabilityOverrideDeactivated', 'pre_00293_backfill', 'mig_00286_post_beta_p5_p7_p8_hardening'),
  -- Money / governance side-effects
  ('ledgerEntryCreated',            'pre_00293_backfill', null),
  ('warningEmitted',                'pre_00293_backfill', null),
  -- Right lifecycle
  ('rightCreated',                  'pre_00293_backfill', null),
  ('rightTransferred',              'pre_00293_backfill', null),
  ('rightDelegated',                'pre_00293_backfill', null),
  ('rightRevoked',                  'pre_00293_backfill', null),
  ('rightExpired',                  'pre_00293_backfill', null),
  ('rightExercised',                'pre_00293_backfill', null),
  ('rightSuspended',                'pre_00293_backfill', null),
  ('rightRestored',                 'pre_00293_backfill', null),
  ('rightExpiringSoon',             'pre_00293_backfill', null),
  ('rightMetadataUpdated',          'pre_00293_backfill', 'update_right_metadata_emit_diff_atom'),
  -- Resource links
  ('resourceLinked',                'pre_00293_backfill', null),
  ('resourceUnlinked',              'pre_00293_backfill', null),
  -- Role lifecycle
  ('roleAssigned',                  'mig_00229',          null),
  ('roleUnassigned',                'mig_00229',          null),
  -- Sprint B + D additions (most recent)
  ('groupRolesChanged',             'mig_00286',          'Sprint B — role catalog mutation atom. Lost twice to parallel branches; recovered in mig 00288 + 00292. Reason this whole table exists.'),
  ('identityPromoted',              'mig_00292',          'Sprint D — verify-otp anon->phone upgrade.')
on conflict (event_type) do nothing;

-- =============================================================================
-- 3. register_event_type helper
-- =============================================================================
create or replace function public.register_event_type(
  p_event_type       text,
  p_source_migration text,
  p_notes            text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_event_type is null or length(trim(p_event_type)) = 0 then
    raise exception 'register_event_type: event_type required';
  end if;
  if p_source_migration is null or length(trim(p_source_migration)) = 0 then
    raise exception 'register_event_type: source_migration required';
  end if;

  insert into public.known_event_types (event_type, source_migration, notes)
  values (trim(p_event_type), trim(p_source_migration), nullif(trim(coalesce(p_notes, '')), ''))
  on conflict (event_type) do nothing;
end;
$$;

revoke execute on function public.register_event_type(text, text, text) from public, anon, authenticated;
-- Service role only: migrations apply as service_role, RPCs don't need to call this.

comment on function public.register_event_type(text, text, text) is
  'Append-only registration of a new system_events atom type. Idempotent (ON CONFLICT DO NOTHING). Service-role only. CALL THIS FROM MIGRATIONS instead of re-shipping is_known_system_event_type. See mig 00293.';

-- =============================================================================
-- 4. Rewrite is_known_system_event_type as STABLE table query
-- =============================================================================
-- IMMUTABLE → STABLE because we now read from a table. The CHECK
-- constraint on system_events.event_type required IMMUTABLE, so we
-- migrate that to a BEFORE INSERT/UPDATE trigger below.

create or replace function public.is_known_system_event_type(p_event_type text)
returns boolean
language sql
stable
parallel safe
set search_path = public
as $function$
  select exists (
    select 1 from public.known_event_types
     where event_type = p_event_type
  );
$function$;

comment on function public.is_known_system_event_type(text) is
  'v17 (mig 00293): table-backed. Queries known_event_types instead of an inline array. To add a new atom type, call register_event_type(...) — NEVER CREATE OR REPLACE this function with a new literal array.';

-- =============================================================================
-- 5. Drop the IMMUTABLE-dependent CHECK; replace with a BEFORE trigger
-- =============================================================================
-- The CHECK depended on the function being IMMUTABLE (Postgres requirement
-- for CHECK expressions). Now that the function is STABLE we can't
-- re-attach the same CHECK; a BEFORE INSERT/UPDATE trigger gives the
-- same validation semantics with table-backed flexibility.

alter table public.system_events
  drop constraint if exists system_events_event_type_known_chk;

create or replace function public.guard_system_events_event_type_known()
returns trigger
language plpgsql
stable
set search_path = public
as $$
begin
  if not public.is_known_system_event_type(new.event_type) then
    raise exception 'unknown system_event event_type: % (register via public.register_event_type before inserting)',
      new.event_type
      using errcode = '23514';  -- check_violation
  end if;
  return new;
end;
$$;

revoke execute on function public.guard_system_events_event_type_known() from public, anon, authenticated;

comment on function public.guard_system_events_event_type_known() is
  'BEFORE INSERT/UPDATE trigger fn: validates system_events.event_type against known_event_types. Replaces the CHECK constraint that depended on is_known_system_event_type being IMMUTABLE (impossible now that it reads from a table).';

drop trigger if exists system_events_event_type_known_trg on public.system_events;
create trigger system_events_event_type_known_trg
  before insert or update of event_type on public.system_events
  for each row
  execute function public.guard_system_events_event_type_known();

comment on trigger system_events_event_type_known_trg on public.system_events is
  'mig 00293: replaces the CHECK constraint system_events_event_type_known_chk.';
