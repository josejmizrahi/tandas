-- 00303 — V24.2: drop group_members.role text column.
--
-- Plans/Active/RolesRemediation_2026-05-17.md V24.2 (final cleanup).
-- Prerequisites already shipped:
--   - mig 00299: is_group_admin reads jsonb (no longer reads role)
--   - mig 00299: sync_group_members_role_text trigger dropped
--   - mig 00299: validate_group_member_role trigger dropped
--   - Sprint V24 iOS commit: Member.isAdmin = holdsRole("admin")
--   - V24.2 iOS commits: Member struct no longer has role field,
--     LiveGroupsRepository SELECTs drop "role" from column lists,
--     myRole derived from rawRoles, GovernanceService fallback removed
--
-- This migration:
--   1. Updates get_member_summary to derive role from roles[] (matches
--      the iOS priority: admin > founder > first known > "member")
--   2. Updates export_my_data similarly
--   3. ALTER TABLE drops the column
--
-- Old iOS builds in the wild WILL break on SELECT "role". Beta-1
-- context: small user base (3 active members all = founder), so the
-- impact is bounded. Users on stale builds will need to update.

-- =============================================================================
-- 1. get_member_summary: derive role from roles[]
-- =============================================================================
create or replace function public.get_member_summary(
  p_group_id uuid,
  p_user_id  uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_member record;
  v_rsvps_total int := 0;
  v_rsvps_going int := 0;
  v_events_attended int := 0;
  v_events_eligible int := 0;
  v_fines_pending_count int := 0;
  v_fines_pending_amount_cents bigint := 0;
  v_fines_paid_count int := 0;
  v_fines_paid_amount_cents bigint := 0;
  v_votes_cast int := 0;
  v_derived_role text;
begin
  if v_caller is null then
    raise exception 'authentication required'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (
    select 1 from public.group_members
     where group_id = p_group_id and user_id = v_caller
  ) then
    raise exception 'not a member of this group'
      using errcode = 'insufficient_privilege';
  end if;

  -- V24.2 (mig 00303): role column dropped. Read roles jsonb instead.
  select id, roles, active, joined_at, on_committee
    into v_member
    from public.group_members
   where group_id = p_group_id and user_id = p_user_id
   limit 1;

  if not found then
    return jsonb_build_object(
      'group_id', p_group_id,
      'user_id', p_user_id,
      'is_member', false,
      'rsvps_total', 0,
      'rsvps_going', 0,
      'events_attended', 0,
      'events_eligible', 0,
      'attendance_rate', null,
      'fines_pending_count', 0,
      'fines_pending_amount_cents', 0,
      'fines_paid_count', 0,
      'fines_paid_amount_cents', 0,
      'votes_cast', 0,
      'joined_at', null,
      'role', null,
      'active', false
    );
  end if;

  -- Derive primary display role from roles[] jsonb. Priority order
  -- matches the iOS LiveGroupsRepository.get derivation so the surface
  -- shape doesn't drift between server-derived and client-derived.
  v_derived_role := case
    when coalesce(v_member.roles, '[]'::jsonb) ? 'admin'   then 'admin'
    when coalesce(v_member.roles, '[]'::jsonb) ? 'founder' then 'founder'
    when jsonb_array_length(coalesce(v_member.roles, '[]'::jsonb)) > 0
         then jsonb_array_element_text(v_member.roles, 0)
    else 'member'
  end;

  select
    count(*) filter (where rsvp_status is not null),
    count(*) filter (where rsvp_status = 'going')
    into v_rsvps_total, v_rsvps_going
    from public.attendance_view
   where group_id = p_group_id and member_id = v_member.id;

  select count(*)
    into v_events_attended
    from public.attendance_view
   where group_id = p_group_id
     and member_id = v_member.id
     and arrived_at is not null;

  select count(*)
    into v_events_eligible
    from public.resources r
   where r.group_id = p_group_id
     and r.resource_type = 'event'
     and r.status in ('closed', 'cancelled')
     and (r.metadata->>'starts_at')::timestamptz >= v_member.joined_at;

  select
    count(*) filter (where status = 'officialized' and not paid and not waived),
    coalesce(sum(amount * 100) filter (where status = 'officialized' and not paid and not waived), 0),
    count(*) filter (where paid),
    coalesce(sum(amount * 100) filter (where paid), 0)
    into v_fines_pending_count, v_fines_pending_amount_cents,
         v_fines_paid_count, v_fines_paid_amount_cents
    from public.fines_view
   where group_id = p_group_id and user_id = p_user_id;

  with my_member_ids as (
    select id from public.group_members
     where group_id = p_group_id and user_id = p_user_id
  )
  select count(*)
    into v_votes_cast
    from public.vote_casts vc
    join public.votes v on v.id = vc.vote_id
   where v.group_id = p_group_id
     and vc.member_id in (select id from my_member_ids)
     and vc.choice <> 'pending';

  return jsonb_build_object(
    'group_id', p_group_id,
    'user_id', p_user_id,
    'is_member', true,
    'rsvps_total', v_rsvps_total,
    'rsvps_going', v_rsvps_going,
    'events_attended', v_events_attended,
    'events_eligible', v_events_eligible,
    'attendance_rate', case
      when v_events_eligible > 0 then round(v_events_attended::numeric / v_events_eligible::numeric, 2)
      else null
    end,
    'fines_pending_count', v_fines_pending_count,
    'fines_pending_amount_cents', v_fines_pending_amount_cents,
    'fines_paid_count', v_fines_paid_count,
    'fines_paid_amount_cents', v_fines_paid_amount_cents,
    'votes_cast', v_votes_cast,
    'joined_at', v_member.joined_at,
    'role', v_derived_role,
    'active', v_member.active,
    'on_committee', v_member.on_committee
  );
end;
$$;

-- =============================================================================
-- 2. export_my_data: derive role per membership from roles[]
-- =============================================================================
create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_member_ids uuid[];
  v_request_id uuid;
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'authentication required'
      using errcode = 'insufficient_privilege';
  end if;

  select coalesce(array_agg(id), '{}'::uuid[]) into v_member_ids
    from public.group_members
   where user_id = v_user_id;

  with
    profile_data as (
      select to_jsonb(p.*) as p
      from public.profiles p where p.id = v_user_id
    ),
    memberships_data as (
      -- V24.2 (mig 00303): role column dropped. Derive primary role
      -- from roles[] jsonb with the same priority order as the iOS
      -- client (admin > founder > first known > "member").
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', gm.id,
        'group_id', gm.group_id,
        'group_name', g.name,
        'role', case
          when coalesce(gm.roles, '[]'::jsonb) ? 'admin'   then 'admin'
          when coalesce(gm.roles, '[]'::jsonb) ? 'founder' then 'founder'
          when jsonb_array_length(coalesce(gm.roles, '[]'::jsonb)) > 0
               then jsonb_array_element_text(gm.roles, 0)
          else 'member'
        end,
        'roles', gm.roles,
        'on_committee', gm.on_committee,
        'turn_order', gm.turn_order,
        'active', gm.active,
        'joined_at', gm.joined_at,
        'display_name_override', gm.display_name_override
      ) order by gm.joined_at), '[]'::jsonb) as ms
      from public.group_members gm
      join public.groups g on g.id = gm.group_id
      where gm.user_id = v_user_id
    ),
    fines_data as (
      select coalesce(jsonb_agg(to_jsonb(f.*) order by f.created_at), '[]'::jsonb) as fs
      from public.fines_view f where f.user_id = v_user_id
    ),
    rsvps_data as (
      select coalesce(jsonb_agg(to_jsonb(r.*) order by r.recorded_at), '[]'::jsonb) as rs
      from public.rsvp_actions r where r.member_id = any(v_member_ids)
    ),
    votes_data as (
      select coalesce(jsonb_agg(jsonb_build_object(
        'vote_id', vc.vote_id,
        'choice', vc.choice,
        'cast_at', vc.cast_at,
        'created_at', vc.created_at,
        'vote_title', v.title,
        'vote_type', v.vote_type
      ) order by vc.created_at), '[]'::jsonb) as vs
      from public.vote_casts vc
      left join public.votes v on v.id = vc.vote_id
      where vc.member_id = any(v_member_ids)
    ),
    events_data as (
      select coalesce(jsonb_agg(to_jsonb(se.*) order by se.occurred_at), '[]'::jsonb) as es
      from public.system_events se
      where se.member_id = any(v_member_ids)
    ),
    ledger_data as (
      select coalesce(jsonb_agg(to_jsonb(le.*) order by le.occurred_at), '[]'::jsonb) as ls
      from public.ledger_entries le
      where le.from_member_id = any(v_member_ids)
         or le.to_member_id = any(v_member_ids)
         or le.recorded_by = v_user_id
    ),
    prefs_data as (
      select coalesce(jsonb_agg(to_jsonb(np.*)), '[]'::jsonb) as ps
      from public.notification_preferences np where np.user_id = v_user_id
    )
  select jsonb_build_object(
    'exported_at', now(),
    'user_id', v_user_id,
    'schema_version', 2,
    'profile', (select p from profile_data),
    'memberships', (select ms from memberships_data),
    'fines', (select fs from fines_data),
    'rsvps', (select rs from rsvps_data),
    'votes', (select vs from votes_data),
    'system_events', (select es from events_data),
    'ledger_entries', (select ls from ledger_data),
    'notification_preferences', (select ps from prefs_data)
  ) into v_result;

  insert into public.data_subject_rights_requests (
    user_id, kind, status, payload, executed_at, result
  ) values (
    v_user_id,
    'portability'::data_right_kind,
    'completed'::data_right_status,
    jsonb_build_object('requested_via', 'export_my_data', 'sync', true),
    now(),
    jsonb_build_object('records_exported', jsonb_build_object(
      'memberships', jsonb_array_length(v_result->'memberships'),
      'fines',       jsonb_array_length(v_result->'fines'),
      'rsvps',       jsonb_array_length(v_result->'rsvps'),
      'votes',       jsonb_array_length(v_result->'votes'),
      'events',      jsonb_array_length(v_result->'system_events'),
      'ledger',      jsonb_array_length(v_result->'ledger_entries')
    ))
  ) returning id into v_request_id;

  return v_result || jsonb_build_object('audit_request_id', v_request_id);
end;
$$;

-- =============================================================================
-- 3. Drop the dependent view, drop the column, recreate the view
-- =============================================================================
-- public.group_members_with_founder uses gm.role in its is_founder
-- computation. Drop the view to free the dependency, drop the column,
-- then recreate the view with jsonb-based is_founder semantics.

drop view if exists public.group_members_with_founder;

alter table public.group_members drop column if exists role;

create view public.group_members_with_founder as
  select gm.id,
         gm.group_id,
         gm.user_id,
         gm.display_name_override,
         gm.on_committee,
         gm.turn_order,
         gm.active,
         gm.joined_at,
         gm.joined_at_event_count,
         gm.roles,
         (coalesce(gm.roles, '[]'::jsonb) ? 'founder' and gm.user_id = g.created_by) as is_founder
    from public.group_members gm
    join public.groups g on g.id = gm.group_id;

comment on view public.group_members_with_founder is
  'v2 (mig 00303): role text column dropped. is_founder now reads roles jsonb (?''founder'') AND tie-breaks against groups.created_by. Exposes the full roles jsonb directly.';
