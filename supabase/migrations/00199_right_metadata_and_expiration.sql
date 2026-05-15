-- Mig 00199: right metadata-update RPC + automatic expiration cron.
--
-- Closes the two gaps left open by mig 00198 (canonical right creation):
--
--   1. `update_right_metadata(p_right_id, p_patch)` — lets admins tune
--      the non-lifecycle knobs (priority, exclusive, transferable,
--      delegable, divisible, expires_at, source, target_resource_id,
--      target_capability, scope, name) after a right has been created.
--      Holder mutation goes ONLY through `transfer_right`; delegate
--      mutation ONLY through `delegate_right`; status transitions
--      ONLY through revoke/suspend/restore/expire — those still write
--      lifecycle atoms. This RPC is the config-write surface so the
--      atom-emitting RPCs can stay narrow.
--
--   2. `expire_due_rights()` SECURITY DEFINER helper + a pg_cron job
--      `expire-due-rights-every-hour` that flips rows from `status='active'`
--      to `status='expired'` once `metadata.expires_at <= now()`, and
--      emits the `rightExpired` atom for each. Closes the loop on the
--      atom that was whitelisted in mig 00198 but never fired.
--
-- Out of scope (deferred):
--   - Lifting suspensions automatically when metadata.suspended_until
--     passes. Suspension is admin-controlled; an explicit
--     `restore_right` call is the canonical recovery path. We don't
--     want a cron silently re-enabling something an admin paused.
--   - Re-emitting a synthetic atom on metadata-only updates (other
--     than rename, which mig 00186's `on_resource_renamed` trigger
--     already covers). Admin tuning of priority/exclusive/transferable
--     is config write, not a lifecycle event.

BEGIN;

-- ============================================================================
-- 1. update_right_metadata RPC
-- ============================================================================
--
-- Allowed patch keys: name, priority, exclusive, transferable, delegable,
-- divisible, expires_at, source, target_resource_id, target_capability,
-- scope. Anything else raises (defensive — closes the door on writes that
-- belong to dedicated lifecycle RPCs).

create or replace function public.update_right_metadata(
  p_right_id  uuid,
  p_patch     jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id    uuid := auth.uid();
  v_group_id     uuid;
  v_metadata     jsonb;
  v_patch_key    text;
  v_allowed_keys text[] := array[
    'name', 'priority', 'exclusive', 'transferable', 'delegable',
    'divisible', 'expires_at', 'source', 'target_resource_id',
    'target_capability', 'scope'
  ];
  v_clean_patch  jsonb := '{}'::jsonb;
  v_target_grp   uuid;
  v_new_scope    text;
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

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'patch must be a jsonb object' using errcode = '22023';
  end if;

  -- Whitelist enforcement + per-key validation.
  for v_patch_key in select * from jsonb_object_keys(p_patch) loop
    if not (v_patch_key = any (v_allowed_keys)) then
      raise exception 'key % cannot be updated via update_right_metadata; use the matching lifecycle RPC',
        v_patch_key using errcode = '42501';
    end if;

    -- scope: enum check.
    if v_patch_key = 'scope' then
      v_new_scope := p_patch->>'scope';
      if v_new_scope is not null and v_new_scope not in ('group', 'resource', 'occurrence') then
        raise exception 'invalid scope %: must be group|resource|occurrence', v_new_scope
          using errcode = '22023';
      end if;
    end if;

    -- target_resource_id: must belong to same group (or null).
    if v_patch_key = 'target_resource_id' then
      if jsonb_typeof(p_patch->'target_resource_id') = 'string' then
        select r.group_id into v_target_grp
          from public.resources r
         where r.id = (p_patch->>'target_resource_id')::uuid;
        if v_target_grp is null then
          raise exception 'target_resource_id not found' using errcode = '22023';
        end if;
        if v_target_grp <> v_group_id then
          raise exception 'target_resource_id belongs to a different group'
            using errcode = '22023';
        end if;
      end if;
    end if;

    -- priority: non-negative integer.
    if v_patch_key = 'priority' then
      if jsonb_typeof(p_patch->'priority') = 'number'
         and (p_patch->>'priority')::int < 0
      then
        raise exception 'priority must be non-negative' using errcode = '22023';
      end if;
    end if;

    -- name: non-empty after trim.
    if v_patch_key = 'name' then
      if jsonb_typeof(p_patch->'name') <> 'string'
         or length(trim(p_patch->>'name')) = 0
      then
        raise exception 'name must be a non-empty string' using errcode = '22023';
      end if;
    end if;

    v_clean_patch := v_clean_patch || jsonb_build_object(v_patch_key, p_patch->v_patch_key);
  end loop;

  if v_clean_patch = '{}'::jsonb then
    return;
  end if;

  update public.resources
     set metadata = metadata || v_clean_patch
   where id = p_right_id;

  -- Name changes already emit `resourceRenamed` via the on_resource_renamed
  -- trigger (mig 00186); other knob changes are config-writes with no
  -- dedicated atom. The audit trail for sensitive knobs (transferable,
  -- expires_at) is reconstructible from the row's update_at + metadata
  -- diff if the founder needs forensics — and the lifecycle RPCs still
  -- enforce the current value at exercise time.
end;
$$;

revoke execute on function public.update_right_metadata(uuid, jsonb) from public, anon;
grant  execute on function public.update_right_metadata(uuid, jsonb) to authenticated;

comment on function public.update_right_metadata(uuid, jsonb) is
  'Tunes the non-lifecycle knobs of a right resource (priority/exclusive/transferable/delegable/divisible/expires_at/source/target_resource_id/target_capability/scope/name). Whitelist enforced — holder/delegate/suspended/status keys are rejected; use the matching lifecycle RPC instead.';

-- ============================================================================
-- 2. expire_due_rights() helper + cron schedule
-- ============================================================================
--
-- The helper flips every active right whose `metadata.expires_at` is in
-- the past to status='expired' and emits a `rightExpired` atom. Returns
-- the row count so the cron log surfaces how many rights expired this
-- tick. Idempotent — a right already in status='expired' is skipped.

create or replace function public.expire_due_rights()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count       int := 0;
  v_row         record;
  v_holder_mem  uuid;
begin
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
       and nullif(r.metadata->>'expires_at','')::timestamptz <= now()
     for update skip locked
  loop
    update public.resources
       set status = 'expired'
     where id = v_row.id
       and status = 'active';  -- defensive against races

    perform public.record_system_event(
      v_row.group_id,
      'rightExpired',
      v_row.id,
      v_row.holder_member_id,
      jsonb_build_object(
        'expired_at',       v_row.expires_at,
        'holder_member_id', v_row.holder_member_id,
        'name',             v_row.metadata->>'name',
        'source',           'cron:expire_due_rights'
      )
    );

    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    raise notice 'expire_due_rights: expired % right(s)', v_count;
  end if;

  return v_count;
end;
$$;

revoke execute on function public.expire_due_rights() from public, anon, authenticated;
grant  execute on function public.expire_due_rights() to service_role;

comment on function public.expire_due_rights() is
  'Cron-driven: flips active rights whose metadata.expires_at <= now() to status=expired and emits rightExpired atom for each. Idempotent.';

-- Schedule the cron. Hourly cadence is enough — rights aren't sub-hour
-- granularity, and the holder/group sees the next activity-feed tick
-- pick up the change. Mirrors `register_dispatch_notifications_cron`
-- pattern.
select cron.schedule(
  'expire-due-rights-every-hour',
  '17 * * * *',  -- minute 17 of every hour to avoid the busy :00 slot
  $$ select public.expire_due_rights(); $$
);

COMMIT;
