-- 00235 — Event RPCs gated on has_permission (Permission catalog v2).
--
-- Sibling of 00232 (fines), 00233 (votes), 00234 (rules). Item #1
-- ("two auth models coexisting"), events slice.
--
-- Catalog gap (fixed in Permission.swift sibling commit):
--   - manageEvents (V1, .governance category): authority over event
--     lifecycle — close, cancel, edit metadata, check in others.
--
-- In scope (5 RPCs)
-- =================
--   - close_event              (mig 00007): admin only
--                              → has_permission('manageEvents')
--   - close_event_no_fines     (mig 00027): admin OR host
--                              → host OR has_permission('manageEvents')
--   - cancel_event             (mig 00215): admin OR host
--                              → host OR has_permission('manageEvents')
--   - update_event_metadata    (mig 00121): admin OR host
--                              → host OR has_permission('manageEvents')
--   - check_in_v2              (mig 00103): self OR admin
--                              → self OR has_permission('manageEvents')
--
-- The "host" exception stays unchanged for cancel/close_no_fines/
-- update — the event host has always controlled their own event and
-- shouldn't need an extra permission to do so. The "self" exception
-- on check_in_v2 stays for the same reason (you can always check in
-- yourself).
--
-- Out of scope (no auth check today)
-- ==================================
--   - create_event_v2: any active member can create an event. If
--     groups want to gate creation per-role, that's a separate slice
--     (would need a new `createEvent` permission).
--   - set_rsvp_v2: self-RSVP only, gate is membership.
--   - link_resource_to_event / unlink_resource_from_event /
--     bulk_close_stale_events: internal/service paths.
--
-- Idempotent: CREATE OR REPLACE swaps function bodies atomically.
-- Backfill is set-union (jsonb_agg distinct), safe to re-run.
--
-- Behaviour for existing founders: zero change. Step 2 adds
-- manageEvents to every founder.permissions in groups.roles and
-- templates.config.defaultRoles.
--
-- Rollback: _rollbacks/00235_rollback.sql restores prior bodies.

-- =========================================================
-- 1. Extend column default on public.groups.roles
-- =========================================================
alter table public.groups
  alter column roles set default
    jsonb_build_object(
      'founder', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array(
          'modifyGovernance',
          'modifyRules',
          'modifyMembers',
          'assignRoles',
          'removeMember',
          'issueFine',
          'voidFine',
          'markFinePaid',
          'closeAppeal',
          'createVotes',
          'manageEvents'
        )
      ),
      'member', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array(
          'createVotes',
          'castVote'
        )
      )
    );

-- =========================================================
-- 2. Backfill existing groups
-- =========================================================
update public.groups
   set roles = jsonb_set(
     roles,
     '{founder,permissions}',
     (
       select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
       from (
         select jsonb_array_elements_text(
           coalesce(roles -> 'founder' -> 'permissions', '[]'::jsonb)
         ) as p
         union
         select unnest(array['manageEvents']) as p
       ) merged
     )
   )
 where roles ? 'founder';

-- =========================================================
-- 3. Backfill templates.config.defaultRoles.founder.permissions
-- =========================================================
update public.templates
   set config = jsonb_set(
     config,
     '{defaultRoles,founder,permissions}',
     (
       select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
       from (
         select jsonb_array_elements_text(
           coalesce(config -> 'defaultRoles' -> 'founder' -> 'permissions', '[]'::jsonb)
         ) as p
         union
         select unnest(array['manageEvents']) as p
       ) merged
     )
   )
 where config -> 'defaultRoles' -> 'founder' is not null;

-- =========================================================
-- 4. close_event — has_permission('manageEvents')
-- =========================================================
create or replace function public.close_event(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  if not public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents') then
    raise exception 'manageEvents permission required' using errcode = '42501';
  end if;

  update public.resources
     set status = 'completed',
         metadata = jsonb_set(metadata, '{closed_at}', to_jsonb(now()::text)),
         updated_at = now()
   where id = p_event_id;

  perform public.record_system_event(
    v_resource.group_id, 'eventClosed', p_event_id, null,
    jsonb_build_object(
      'title', v_resource.metadata->>'title',
      'closed_at', now(),
      'status', 'completed'
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.close_event(uuid) is
  'v2 (mig 00235): auth gate is has_permission(manageEvents) instead of is_group_admin.';

-- =========================================================
-- 5. close_event_no_fines — host OR has_permission('manageEvents')
-- =========================================================
create or replace function public.close_event_no_fines(p_event_id uuid)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  update public.resources
     set status = 'completed',
         metadata = jsonb_set(metadata, '{closed_at}', to_jsonb(now()::text)),
         updated_at = now()
   where id = p_event_id;

  perform public.record_system_event(
    v_resource.group_id, 'eventClosed', p_event_id, null,
    jsonb_build_object(
      'title', v_resource.metadata->>'title',
      'closed_at', now(),
      'status', 'completed'
    )
  );

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.close_event_no_fines(uuid) is
  'v2 (mig 00235): auth gate is host OR has_permission(manageEvents) instead of host OR is_group_admin.';

-- =========================================================
-- 6. cancel_event — host OR has_permission('manageEvents')
-- =========================================================
create or replace function public.cancel_event(p_event_id uuid, p_reason text default null)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_view_row public.events_view;
  v_host_id  uuid;
begin
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  -- The status UPDATE fires the on_event_status_cancelled trigger which
  -- emits the `eventCancelled` atom. We deliberately do NOT emit
  -- `eventClosed` here anymore — see mig 00209 header for rationale.
  update public.resources
     set status   = 'cancelled',
         metadata = case
           when p_reason is null then metadata
           else jsonb_set(metadata, '{cancellation_reason}', to_jsonb(p_reason::text))
         end,
         updated_at = now()
   where id = p_event_id;

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.cancel_event(uuid, text) is
  'v2 (mig 00235): auth gate is host OR has_permission(manageEvents) instead of host OR is_group_admin.';

-- =========================================================
-- 7. update_event_metadata — host OR has_permission('manageEvents')
-- =========================================================
create or replace function public.update_event_metadata(p_event_id uuid, p_patch jsonb)
returns public.events_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource public.resources;
  v_host_id  uuid;
  v_view_row public.events_view;
begin
  select * into v_resource from public.resources
   where id = p_event_id and resource_type = 'event';
  if v_resource.id is null then raise exception 'event not found'; end if;

  v_host_id := (v_resource.metadata->>'host_id')::uuid;
  if not (v_host_id = auth.uid()
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'host or manageEvents permission required' using errcode = '42501';
  end if;

  update public.resources
     set metadata = metadata || p_patch,
         updated_at = now()
   where id = p_event_id;

  select * into v_view_row from public.events_view where id = p_event_id;
  return v_view_row;
end;
$$;

comment on function public.update_event_metadata(uuid, jsonb) is
  'v2 (mig 00235): auth gate is host OR has_permission(manageEvents) instead of host OR is_group_admin.';

-- =========================================================
-- 8. check_in_v2 — self OR has_permission('manageEvents')
-- =========================================================
create or replace function public.check_in_v2(
  p_event_id           uuid,
  p_user_id            uuid,
  p_method             text default 'self',
  p_location_verified  boolean default false,
  p_arrived_at         timestamptz default null
)
returns public.attendance_view
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resource  public.resources;
  v_member_id uuid;
  v_view_row  public.attendance_view;
begin
  if p_method not in ('self', 'qr_scan', 'host_marked') then
    raise exception 'invalid method: %', p_method;
  end if;
  select * into v_resource from public.resources where id = p_event_id and resource_type='event';
  if v_resource.id is null then raise exception 'event not found'; end if;
  if not (auth.uid() = p_user_id
          or public.has_permission(v_resource.group_id, auth.uid(), 'manageEvents')) then
    raise exception 'self or manageEvents permission required' using errcode = '42501';
  end if;

  select id into v_member_id from public.group_members
   where group_id = v_resource.group_id and user_id = p_user_id limit 1;
  if v_member_id is null then raise exception 'membership not found'; end if;

  insert into public.check_in_actions (
    resource_id, member_id, arrived_at, metadata
  ) values (
    p_event_id, v_member_id, coalesce(p_arrived_at, now()),
    jsonb_strip_nulls(jsonb_build_object(
      'check_in_method', p_method,
      'check_in_location_verified', coalesce(p_location_verified, false),
      'marked_by', auth.uid(),
      'via', 'check_in_v2'
    ))
  );

  select * into v_view_row from public.attendance_view
   where resource_id = p_event_id and member_id = v_member_id;
  return v_view_row;
end;
$$;

comment on function public.check_in_v2(uuid, uuid, text, boolean, timestamptz) is
  'v2 (mig 00235): auth gate is self OR has_permission(manageEvents) instead of self OR is_group_admin. Self check-in always allowed without permission.';
