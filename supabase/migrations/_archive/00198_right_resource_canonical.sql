-- Mig 00198: Canonical `right` resource type — first-class creation +
-- lifecycle atoms.
--
-- Context
-- =======
-- Constitution §1 art. 2 froze `resources.resource_type` to 6 canonical
-- values (mig 00147). `right` was admitted as the normative layer:
-- "quién tiene un claim legítimo sobre algo" — a derecho, no un
-- permission flag. It has existed structurally since the freeze (CHECK
-- accepts it, status whitelist accepts 'active'/'expired'/'revoked' per
-- mig 00185), but there has been NO creation path, no lifecycle atoms
-- and no projection: a user could not materialise a `right` resource
-- end-to-end from iOS.
--
-- This migration ships the canonical implementation:
--
--   1. Eight `right.*` lifecycle atoms added to is_known_system_event_type
--      whitelist (rightCreated/Transferred/Delegated/Revoked/Expired/
--      Exercised/Suspended/Restored).
--   2. `create_right` RPC — any group member may create a right scoped
--      to a holder, optionally referencing a target resource + capability,
--      with scope/priority/exclusivity/transferability/delegability/
--      divisibility/expiration knobs persisted in `resources.metadata`.
--   3. `transfer_right`, `delegate_right`, `revoke_right`,
--      `suspend_right`, `restore_right`, `exercise_right` lifecycle
--      RPCs — each emits the matching atom and updates metadata /
--      status as needed.
--   4. `build_resource_from_draft` extended with a `right` branch so the
--      iOS ResourceWizard can submit drafts atomically.
--   5. `right_holders_view` projection — current holder + status +
--      target context per right (read-only; derived from
--      `resources WHERE resource_type='right'`).
--
-- Doctrinal anchor
-- ================
-- A `right` resource records a NORMATIVE claim, not a permission grant:
--   - holder            : group_members.id who owns the right
--   - target_resource   : optional Resource this right governs
--   - target_capability : optional Capability id (booking/voting/access/…)
--                         that the right grants leverage over
--   - scope             : 'group' | 'resource' | 'occurrence'
--   - priority          : integer; higher = stronger precedence
--   - exclusive         : boolean; true = no concurrent peer holders
--   - transferable      : boolean
--   - delegable         : boolean
--   - divisible         : boolean (fractional ownership / equity)
--   - expires_at        : timestamptz (NULL = open-ended)
--   - source            : human-readable origin string ("constitution",
--                         "purchase", "inheritance", "vote_2026-05")
--
-- Atoms are append-only: every transfer/delegation/revocation lands as
-- a separate `system_events` row carrying old/new holder + reason +
-- source atom id when applicable. The `right_holders_view` projection
-- reads `resources.metadata` directly (current state) — the full
-- transfer chain is recoverable by querying `system_events WHERE
-- event_type LIKE 'right%' AND resource_id = :right_id`.
--
-- Out of scope (intentional)
-- ==========================
-- - Rule engine evaluators for the new atoms. Whitelist + emit suffice
--   for atom-side correctness; downstream consequences (e.g. revoke a
--   right when fines accrue past threshold) land as rule templates in a
--   later slice once the demand pull arrives.
-- - Dispatch into `notifications_outbox`. Right lifecycle events are
--   visible in the activity feed; targeted notifications wait for
--   product feedback on noise vs. signal.
-- - Fractional / divisible ownership math. The flag is persisted so the
--   UX can surface "divisible" / "20% equity", but balance projection
--   stays a follow-up — divisible rights with no LedgerEntry tie-in are
--   simply documented intent today.
--
-- Companion changes (same PR):
--   - SystemEventType.swift   — 8 new cases + regenerated codec
--   - systemEventType.ts      — regenerated
--   - RightResourceBuilder.swift — wizard surface
--   - AppState wiring         — registers the builder
--   - ResourceBuilderRegistry — surfaces `right` instead of placeholder

BEGIN;

-- ============================================================================
-- 1. SystemEventType whitelist — add 8 right.* atoms
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
    -- mig 00198: canonical `right` resource_type lifecycle atoms.
    -- Append-only. See create_right + lifecycle RPCs below.
    'rightCreated', 'rightTransferred', 'rightDelegated', 'rightRevoked',
    'rightExpired', 'rightExercised', 'rightSuspended', 'rightRestored'
  ]);
$function$;

comment on function public.is_known_system_event_type(text) is
  'Whitelist check for system_events.event_type values. Mirrors the SystemEventType Swift enum + TS shared/types. v8 (00198): added 8 right.* lifecycle atoms.';

-- ============================================================================
-- 2. create_right RPC
-- ============================================================================
--
-- Any group member may instantiate a right. The holder must be an active
-- member of the same group. target_resource_id, when set, must point at
-- a resource owned by the same group (no cross-group rights — those are
-- horizon, not present per Constitution art. 4).

create or replace function public.create_right(
  p_group_id            uuid,
  p_name                text,
  p_holder_member_id    uuid,
  p_target_resource_id  uuid     default null,
  p_target_capability   text     default null,
  p_scope               text     default 'resource',
  p_priority            int      default 0,
  p_exclusive           boolean  default false,
  p_transferable        boolean  default false,
  p_delegable           boolean  default false,
  p_divisible           boolean  default false,
  p_expires_at          timestamptz default null,
  p_source              text     default null,
  p_extra               jsonb    default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id   uuid := auth.uid();
  v_right_id    uuid;
  v_holder_uid  uuid;
  v_target_grp  uuid;
  v_metadata    jsonb;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if not public.is_group_member(p_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'right name required' using errcode = '22023';
  end if;

  if p_holder_member_id is null then
    raise exception 'right holder required' using errcode = '22023';
  end if;

  -- holder must be an active member of the same group. We accept a
  -- group_members.id (membership row id) rather than a user_id so the
  -- right is bound to the holder's relationship to the group, not their
  -- global identity — matches Constitution art. 4 (User → Membership).
  select gm.user_id into v_holder_uid
    from public.group_members gm
   where gm.id = p_holder_member_id
     and gm.group_id = p_group_id
     and gm.active = true;

  if v_holder_uid is null then
    raise exception 'right holder must be an active member of the same group'
      using errcode = '22023';
  end if;

  if p_scope not in ('group', 'resource', 'occurrence') then
    raise exception 'invalid scope %: must be group|resource|occurrence', p_scope
      using errcode = '22023';
  end if;

  -- Cross-resource integrity: target resource (if any) must belong to
  -- the same group. Doctrine: a right cannot reach across group
  -- boundaries.
  if p_target_resource_id is not null then
    select r.group_id into v_target_grp
      from public.resources r
     where r.id = p_target_resource_id;
    if v_target_grp is null then
      raise exception 'target_resource_id not found' using errcode = '22023';
    end if;
    if v_target_grp <> p_group_id then
      raise exception 'target_resource_id belongs to a different group'
        using errcode = '22023';
    end if;
  end if;

  if p_priority < 0 then
    raise exception 'priority must be non-negative' using errcode = '22023';
  end if;

  v_metadata := coalesce(p_extra, '{}'::jsonb) || jsonb_build_object(
    'name',                p_name,
    'holder_member_id',    p_holder_member_id,
    'holder_user_id',      v_holder_uid,
    'target_resource_id',  p_target_resource_id,
    'target_capability',   p_target_capability,
    'scope',               p_scope,
    'priority',            p_priority,
    'exclusive',           p_exclusive,
    'transferable',        p_transferable,
    'delegable',           p_delegable,
    'divisible',           p_divisible,
    'expires_at',          p_expires_at,
    'source',              p_source
  );

  insert into public.resources (group_id, resource_type, status, metadata, created_by)
  values (
    p_group_id,
    'right',
    'active',
    v_metadata,
    v_caller_id
  )
  returning id into v_right_id;

  perform public.record_system_event(
    p_group_id,
    'rightCreated',
    v_right_id,
    p_holder_member_id,
    jsonb_build_object(
      'name',               p_name,
      'holder_member_id',   p_holder_member_id,
      'target_resource_id', p_target_resource_id,
      'target_capability',  p_target_capability,
      'scope',              p_scope,
      'priority',           p_priority,
      'exclusive',          p_exclusive,
      'transferable',       p_transferable,
      'delegable',          p_delegable,
      'divisible',          p_divisible,
      'expires_at',         p_expires_at,
      'source',             p_source,
      'created_by',         v_caller_id
    )
  );

  return v_right_id;
end;
$$;

revoke execute on function public.create_right(
  uuid, text, uuid, uuid, text, text, int, boolean, boolean, boolean, boolean,
  timestamptz, text, jsonb
) from public, anon;
grant  execute on function public.create_right(
  uuid, text, uuid, uuid, text, text, int, boolean, boolean, boolean, boolean,
  timestamptz, text, jsonb
) to authenticated;

comment on function public.create_right(
  uuid, text, uuid, uuid, text, text, int, boolean, boolean, boolean, boolean,
  timestamptz, text, jsonb
) is
  'Create a `right` resource (Constitution §1 art. 2, sixth canonical type). Any group member may call; holder must be an active member of p_group_id; target resource (when supplied) must belong to the same group. Emits rightCreated atom. Returns the new resource id.';

-- ============================================================================
-- 3. Lifecycle RPCs — transfer / delegate / revoke / suspend / restore /
--    exercise. Each emits the matching `right.*` atom and updates
--    metadata + status as appropriate.
-- ============================================================================

-- 3a) transfer_right — assigns the right to a new holder. Requires
-- transferable=true. Emits rightTransferred.

create or replace function public.transfer_right(
  p_right_id        uuid,
  p_to_member_id    uuid,
  p_reason          text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_metadata      jsonb;
  v_from_member   uuid;
  v_to_user       uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select r.group_id, r.metadata
    into v_group_id, v_metadata
    from public.resources r
   where r.id = p_right_id
     and r.resource_type = 'right'
     and r.archived_at is null;

  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if coalesce((v_metadata->>'transferable')::boolean, false) is not true then
    raise exception 'right is not transferable' using errcode = '42501';
  end if;

  -- Holder, transferee. Transferee must be an active group member.
  v_from_member := (v_metadata->>'holder_member_id')::uuid;

  select gm.user_id into v_to_user
    from public.group_members gm
   where gm.id = p_to_member_id
     and gm.group_id = v_group_id
     and gm.active = true;
  if v_to_user is null then
    raise exception 'new holder must be an active member of the same group'
      using errcode = '22023';
  end if;

  update public.resources
     set metadata = metadata
                  || jsonb_build_object(
                       'holder_member_id', p_to_member_id,
                       'holder_user_id',   v_to_user
                     )
   where id = p_right_id;

  perform public.record_system_event(
    v_group_id,
    'rightTransferred',
    p_right_id,
    p_to_member_id,
    jsonb_build_object(
      'from_member_id', v_from_member,
      'to_member_id',   p_to_member_id,
      'transferred_by', v_caller_id,
      'reason',         p_reason
    )
  );
end;
$$;

revoke execute on function public.transfer_right(uuid, uuid, text) from public, anon;
grant  execute on function public.transfer_right(uuid, uuid, text) to authenticated;

comment on function public.transfer_right(uuid, uuid, text) is
  'Reassigns a transferable right to a new holder. Both holder and transferee must be active members of the right''s group. Emits rightTransferred.';

-- 3b) delegate_right — grants temporary exercise to a delegate without
-- changing primary ownership. Stores delegate in metadata.delegate_member_id.
-- Requires delegable=true. Emits rightDelegated.

create or replace function public.delegate_right(
  p_right_id          uuid,
  p_delegate_member_id uuid,
  p_until             timestamptz default null,
  p_reason            text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_metadata      jsonb;
  v_delegate_user uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select r.group_id, r.metadata
    into v_group_id, v_metadata
    from public.resources r
   where r.id = p_right_id
     and r.resource_type = 'right'
     and r.archived_at is null;

  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if coalesce((v_metadata->>'delegable')::boolean, false) is not true then
    raise exception 'right is not delegable' using errcode = '42501';
  end if;

  select gm.user_id into v_delegate_user
    from public.group_members gm
   where gm.id = p_delegate_member_id
     and gm.group_id = v_group_id
     and gm.active = true;
  if v_delegate_user is null then
    raise exception 'delegate must be an active member of the same group'
      using errcode = '22023';
  end if;

  update public.resources
     set metadata = metadata
                  || jsonb_build_object(
                       'delegate_member_id', p_delegate_member_id,
                       'delegate_user_id',   v_delegate_user,
                       'delegate_until',     p_until
                     )
   where id = p_right_id;

  perform public.record_system_event(
    v_group_id,
    'rightDelegated',
    p_right_id,
    p_delegate_member_id,
    jsonb_build_object(
      'delegate_member_id', p_delegate_member_id,
      'until',              p_until,
      'delegated_by',       v_caller_id,
      'reason',             p_reason
    )
  );
end;
$$;

revoke execute on function public.delegate_right(uuid, uuid, timestamptz, text) from public, anon;
grant  execute on function public.delegate_right(uuid, uuid, timestamptz, text) to authenticated;

comment on function public.delegate_right(uuid, uuid, timestamptz, text) is
  'Records a temporary delegation of a delegable right. Holder unchanged; delegate stored in metadata.delegate_member_id with optional metadata.delegate_until. Emits rightDelegated.';

-- 3c) revoke_right — flips status=revoked. Emits rightRevoked. Soft —
-- the row stays in `resources`; the projection filters by status.

create or replace function public.revoke_right(
  p_right_id  uuid,
  p_reason    text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
  v_status    text;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select r.group_id, r.status
    into v_group_id, v_status
    from public.resources r
   where r.id = p_right_id
     and r.resource_type = 'right'
     and r.archived_at is null;

  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if v_status = 'revoked' then
    return; -- idempotent
  end if;

  update public.resources
     set status = 'revoked'
   where id = p_right_id;

  perform public.record_system_event(
    v_group_id,
    'rightRevoked',
    p_right_id,
    null,
    jsonb_build_object(
      'previous_status', v_status,
      'revoked_by',      v_caller_id,
      'reason',          p_reason
    )
  );
end;
$$;

revoke execute on function public.revoke_right(uuid, text) from public, anon;
grant  execute on function public.revoke_right(uuid, text) to authenticated;

comment on function public.revoke_right(uuid, text) is
  'Sets a right''s status to revoked and emits rightRevoked. Idempotent. Row stays in resources; projections filter by status.';

-- 3d) suspend_right — temporary inability to exercise. Status stays
-- 'active' (so it can be restored without rejoining the canonical set)
-- but metadata.suspended_until carries the lift date. Emits rightSuspended.

create or replace function public.suspend_right(
  p_right_id  uuid,
  p_until     timestamptz default null,
  p_reason    text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select r.group_id
    into v_group_id
    from public.resources r
   where r.id = p_right_id
     and r.resource_type = 'right'
     and r.archived_at is null;

  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  update public.resources
     set metadata = metadata
                  || jsonb_build_object(
                       'suspended_at',    now(),
                       'suspended_until', p_until,
                       'suspended_by',    v_caller_id
                     )
   where id = p_right_id;

  perform public.record_system_event(
    v_group_id,
    'rightSuspended',
    p_right_id,
    null,
    jsonb_build_object(
      'until',        p_until,
      'suspended_by', v_caller_id,
      'reason',       p_reason
    )
  );
end;
$$;

revoke execute on function public.suspend_right(uuid, timestamptz, text) from public, anon;
grant  execute on function public.suspend_right(uuid, timestamptz, text) to authenticated;

comment on function public.suspend_right(uuid, timestamptz, text) is
  'Records a temporary suspension via metadata.suspended_until (status stays active). Emits rightSuspended. Pair with restore_right.';

-- 3e) restore_right — clears the suspension. Emits rightRestored.

create or replace function public.restore_right(
  p_right_id  uuid,
  p_reason    text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_group_id  uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select r.group_id
    into v_group_id
    from public.resources r
   where r.id = p_right_id
     and r.resource_type = 'right'
     and r.archived_at is null;

  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  update public.resources
     set metadata = metadata
                  - 'suspended_at'
                  - 'suspended_until'
                  - 'suspended_by',
         status   = case when status = 'revoked' then 'active' else status end
   where id = p_right_id;

  perform public.record_system_event(
    v_group_id,
    'rightRestored',
    p_right_id,
    null,
    jsonb_build_object(
      'restored_by', v_caller_id,
      'reason',      p_reason
    )
  );
end;
$$;

revoke execute on function public.restore_right(uuid, text) from public, anon;
grant  execute on function public.restore_right(uuid, text) to authenticated;

comment on function public.restore_right(uuid, text) is
  'Clears a suspension (and lifts a revocation back to active). Emits rightRestored.';

-- 3f) exercise_right — atom-only. Records that the holder USED the
-- right (booked the palco, voted with their equity, accessed the asset).
-- Status unchanged; metadata gets a `last_exercised_at` stamp.

create or replace function public.exercise_right(
  p_right_id  uuid,
  p_context   jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id   uuid := auth.uid();
  v_group_id    uuid;
  v_metadata    jsonb;
  v_holder_uid  uuid;
  v_caller_mem  uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select r.group_id, r.metadata
    into v_group_id, v_metadata
    from public.resources r
   where r.id = p_right_id
     and r.resource_type = 'right'
     and r.archived_at is null;

  if v_group_id is null then
    raise exception 'right % not found or archived', p_right_id using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  -- Only the holder, an active delegate, or someone with the group's
  -- governance override can exercise. We check holder/delegate here;
  -- governance-side overrides land via the rule engine, not this RPC.
  v_holder_uid := (v_metadata->>'holder_user_id')::uuid;

  if v_caller_id <> v_holder_uid
     and v_caller_id <> nullif(v_metadata->>'delegate_user_id', '')::uuid
  then
    raise exception 'caller is neither holder nor active delegate of this right'
      using errcode = '42501';
  end if;

  select gm.id into v_caller_mem
    from public.group_members gm
   where gm.group_id = v_group_id
     and gm.user_id  = v_caller_id
     and gm.active   = true
   limit 1;

  update public.resources
     set metadata = metadata
                  || jsonb_build_object('last_exercised_at', now())
   where id = p_right_id;

  perform public.record_system_event(
    v_group_id,
    'rightExercised',
    p_right_id,
    v_caller_mem,
    jsonb_build_object(
      'exercised_by_user_id',   v_caller_id,
      'exercised_by_member_id', v_caller_mem,
      'context',                coalesce(p_context, '{}'::jsonb)
    )
  );
end;
$$;

revoke execute on function public.exercise_right(uuid, jsonb) from public, anon;
grant  execute on function public.exercise_right(uuid, jsonb) to authenticated;

comment on function public.exercise_right(uuid, jsonb) is
  'Records an exercise event (holder or delegate used the right). Updates metadata.last_exercised_at; emits rightExercised with caller context.';

-- ============================================================================
-- 4. build_resource_from_draft — right branch
-- ============================================================================

create or replace function public.build_resource_from_draft(
  p_group_id              uuid,
  p_resource_type         text,
  p_basic_fields          jsonb,
  p_enabled_capabilities  text[],
  p_capability_configs    jsonb,
  p_series_pattern        jsonb,
  p_initial_rules         jsonb
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid               uuid := auth.uid();
  v_resource_id       uuid;
  v_series_id         uuid;
  v_capability        text;
  v_rule              jsonb;
  v_rule_name         text;
  v_event_starts_at   timestamptz;
  v_event_title       text;
  v_event_duration    int;
  v_event_location    text;
  v_event_description text;
  v_event_deadline    timestamptz;
  v_rsvp_deadline_raw text;
  v_series_metadata   jsonb;
  v_asset_name        text;
  v_asset_capacity    int;
  v_fund_name         text;
  v_fund_target       bigint;
  v_fund_currency     text;
  v_right_name        text;
  v_right_holder      uuid;
  v_right_target      uuid;
  v_right_capability  text;
  v_right_scope       text;
  v_right_priority    int;
  v_right_exclusive   boolean;
  v_right_transfer    boolean;
  v_right_delegable   boolean;
  v_right_divisible   boolean;
  v_right_expires_at  timestamptz;
  v_right_source      text;
  v_right_expires_raw text;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;

  if not public.is_group_member(p_group_id, v_uid) then
    raise exception 'not a member of this group';
  end if;

  if p_series_pattern is not null and p_series_pattern <> '{}'::jsonb then
    v_series_metadata := coalesce(p_basic_fields, '{}'::jsonb);
    if p_capability_configs is not null and p_capability_configs <> '{}'::jsonb then
      v_series_metadata := v_series_metadata
        || jsonb_build_object('capability_configs', p_capability_configs);
    end if;

    insert into public.resource_series (
      group_id, resource_type, pattern, metadata, created_by
    )
    values (
      p_group_id,
      p_resource_type,
      p_series_pattern,
      v_series_metadata,
      v_uid
    )
    returning id into v_series_id;
  end if;

  case p_resource_type
  when 'event' then
    v_event_title       := p_basic_fields->>'title';
    v_event_starts_at   := (p_basic_fields->>'startsAt')::timestamptz;
    v_event_duration    := coalesce((p_basic_fields->>'durationMinutes')::int, 180);
    v_event_location    := p_basic_fields->>'location';
    v_event_description := p_basic_fields->>'description';

    if v_event_title is null or length(trim(v_event_title)) < 1 then
      raise exception 'event title required';
    end if;
    if v_event_starts_at is null then
      raise exception 'event startsAt required';
    end if;

    if p_capability_configs is not null then
      v_rsvp_deadline_raw := nullif(
        trim(coalesce(p_capability_configs->'rsvp'->>'deadline', '')),
        ''
      );
      if v_rsvp_deadline_raw is not null then
        begin
          v_event_deadline := v_rsvp_deadline_raw::timestamptz;
        exception when others then
          v_event_deadline := null;
        end;
      end if;
    end if;

    select e.id into v_resource_id
      from public.create_event_v2(
        p_group_id            := p_group_id,
        p_title               := v_event_title,
        p_starts_at           := v_event_starts_at,
        p_duration_minutes    := v_event_duration,
        p_location_name       := v_event_location,
        p_location_lat        := null,
        p_location_lng        := null,
        p_host_id             := null,
        p_cover_image_name    := null,
        p_cover_image_url     := null,
        p_description         := v_event_description,
        p_apply_rules         := true,
        p_is_recurring_generated := false,
        p_rsvp_deadline       := v_event_deadline
      ) as e;

  when 'asset' then
    v_asset_name     := p_basic_fields->>'name';
    v_asset_capacity := (p_basic_fields->>'capacity')::int;

    if v_asset_name is null or length(trim(v_asset_name)) < 1 then
      raise exception 'asset name required';
    end if;

    v_resource_id := public.create_asset(
      p_group_id := p_group_id,
      p_name     := v_asset_name,
      p_capacity := v_asset_capacity
    );

  when 'fund' then
    v_fund_name     := p_basic_fields->>'name';
    v_fund_target   := nullif(p_basic_fields->>'targetAmountCents', '')::bigint;
    v_fund_currency := coalesce(p_basic_fields->>'currency', 'MXN');

    if v_fund_name is null or length(trim(v_fund_name)) < 1 then
      raise exception 'fund name required';
    end if;

    v_resource_id := public.create_fund(
      p_group_id            := p_group_id,
      p_name                := v_fund_name,
      p_target_amount_cents := v_fund_target,
      p_currency            := v_fund_currency
    );

  when 'right' then
    -- mig 00198: canonical `right` creation via wizard. Same shape
    -- as create_right RPC — the field names mirror the iOS
    -- RightResourceBuilder's BuilderField keys.
    v_right_name       := p_basic_fields->>'name';
    v_right_holder     := nullif(p_basic_fields->>'holderMemberId', '')::uuid;
    v_right_target     := nullif(p_basic_fields->>'targetResourceId', '')::uuid;
    v_right_capability := nullif(p_basic_fields->>'targetCapability', '');
    v_right_scope      := coalesce(nullif(p_basic_fields->>'scope', ''), 'resource');
    v_right_priority   := coalesce(nullif(p_basic_fields->>'priority', '')::int, 0);
    v_right_exclusive  := coalesce((p_basic_fields->>'exclusive')::boolean,    false);
    v_right_transfer   := coalesce((p_basic_fields->>'transferable')::boolean, false);
    v_right_delegable  := coalesce((p_basic_fields->>'delegable')::boolean,    false);
    v_right_divisible  := coalesce((p_basic_fields->>'divisible')::boolean,    false);
    v_right_source     := nullif(p_basic_fields->>'source', '');

    v_right_expires_raw := nullif(p_basic_fields->>'expiresAt', '');
    if v_right_expires_raw is not null then
      begin
        v_right_expires_at := v_right_expires_raw::timestamptz;
      exception when others then
        v_right_expires_at := null;
      end;
    end if;

    if v_right_name is null or length(trim(v_right_name)) < 1 then
      raise exception 'right name required';
    end if;
    if v_right_holder is null then
      raise exception 'right holder required';
    end if;

    v_resource_id := public.create_right(
      p_group_id            := p_group_id,
      p_name                := v_right_name,
      p_holder_member_id    := v_right_holder,
      p_target_resource_id  := v_right_target,
      p_target_capability   := v_right_capability,
      p_scope               := v_right_scope,
      p_priority            := v_right_priority,
      p_exclusive           := v_right_exclusive,
      p_transferable        := v_right_transfer,
      p_delegable           := v_right_delegable,
      p_divisible           := v_right_divisible,
      p_expires_at          := v_right_expires_at,
      p_source              := v_right_source
    );

  else
    raise exception 'resource_type % not supported by build_resource_from_draft yet', p_resource_type;
  end case;

  if v_series_id is not null then
    update public.resources
       set series_id = v_series_id
     where id = v_resource_id;
  end if;

  if p_enabled_capabilities is not null then
    foreach v_capability in array p_enabled_capabilities loop
      insert into public.resource_capabilities (
        resource_id,
        capability_block_id,
        config,
        enabled,
        enabled_by
      )
      values (
        v_resource_id,
        v_capability,
        coalesce(p_capability_configs->v_capability, '{}'::jsonb),
        true,
        v_uid
      )
      on conflict (resource_id, capability_block_id)
        do update set
          enabled = excluded.enabled,
          config  = excluded.config,
          enabled_by = excluded.enabled_by,
          enabled_at = now();
    end loop;
  end if;

  if p_initial_rules is not null and jsonb_array_length(p_initial_rules) > 0 then
    for v_rule in
      select * from jsonb_array_elements(p_initial_rules)
    loop
      v_rule_name := coalesce(v_rule->>'name', 'Regla sin nombre');
      insert into public.rules (
        group_id, resource_id, slug, name, is_active,
        trigger, conditions, consequences,
        module_key, series_id, membership_id,
        proposed_by
      )
      values (
        p_group_id,
        v_resource_id,
        v_rule->>'slug',
        v_rule_name,
        coalesce((v_rule->>'isActive')::boolean, true),
        coalesce(v_rule->'trigger', '{}'::jsonb),
        coalesce(v_rule->'conditions', '[]'::jsonb),
        coalesce(v_rule->'consequences', '[]'::jsonb),
        null,
        v_series_id,
        null,
        v_uid
      );
    end loop;
  end if;

  return v_resource_id;
end;
$$;

comment on function public.build_resource_from_draft(uuid, text, jsonb, text[], jsonb, jsonb, jsonb) is
  'Atomic ResourceWizard submit. v5 (00198): added `right` branch — calls create_right with name + holder + target + scope + priority + exclusivity/transferability/delegability/divisibility + expires_at + source from basic_fields.';

-- ============================================================================
-- 5. right_holders_view projection
-- ============================================================================
--
-- Current state of every `right` resource: who holds it, what it points
-- at, lifecycle status. Read-only; recomputable. The full transfer +
-- delegation history lives in `system_events WHERE event_type LIKE
-- 'right%'` and is the source of truth.

drop view if exists public.right_holders_view;
create view public.right_holders_view
with (security_invoker = true) as
  select
    r.id                                     as right_id,
    r.group_id,
    r.status,
    r.metadata->>'name'                      as name,
    (r.metadata->>'holder_member_id')::uuid  as holder_member_id,
    (r.metadata->>'holder_user_id')::uuid    as holder_user_id,
    nullif(r.metadata->>'delegate_member_id','')::uuid as delegate_member_id,
    nullif(r.metadata->>'delegate_user_id','')::uuid   as delegate_user_id,
    nullif(r.metadata->>'delegate_until','')::timestamptz as delegate_until,
    nullif(r.metadata->>'target_resource_id','')::uuid as target_resource_id,
    nullif(r.metadata->>'target_capability','')        as target_capability,
    coalesce(r.metadata->>'scope', 'resource')         as scope,
    coalesce((r.metadata->>'priority')::int, 0)        as priority,
    coalesce((r.metadata->>'exclusive')::boolean, false)    as exclusive,
    coalesce((r.metadata->>'transferable')::boolean, false) as transferable,
    coalesce((r.metadata->>'delegable')::boolean, false)    as delegable,
    coalesce((r.metadata->>'divisible')::boolean, false)    as divisible,
    nullif(r.metadata->>'expires_at','')::timestamptz       as expires_at,
    nullif(r.metadata->>'suspended_until','')::timestamptz  as suspended_until,
    nullif(r.metadata->>'last_exercised_at','')::timestamptz as last_exercised_at,
    nullif(r.metadata->>'source','')                         as source,
    r.created_by,
    r.created_at,
    r.updated_at,
    r.archived_at
  from public.resources r
  where r.resource_type = 'right';

comment on view public.right_holders_view is
  'Projection of `right` resources — current holder, delegate, target context, priority and lifecycle flags. RLS inherits from public.resources (security_invoker=true). The full transfer chain is recoverable from system_events WHERE event_type LIKE ''right%'' AND resource_id = :id.';

grant select on public.right_holders_view to authenticated;

COMMIT;
