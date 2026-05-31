-- Mig 00318: discover_pending_placeholders + get_placeholder_history_summary.
--
-- discover: post-login the iOS client calls this to find placeholders whose
-- phone matches the caller's auth.users.phone (Camino B in the spec).
--
-- summary: shown to user in ClaimReviewView before they accept/decline.
-- Returns counts of fines/votes/events attributed to the placeholder so
-- they can make an informed decision. Both fines and vote_casts join via
-- the placeholder's group_members.id (member_id) for counts that survive
-- the future merge unchanged.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §11.2, §11.3

create or replace function public.discover_pending_placeholders()
returns table (
  placeholder_uid uuid,
  group_id uuid,
  group_name text,
  display_name text,
  invite_id uuid
)
language sql security definer set search_path = public, pg_catalog
as $$
  select
    p.id as placeholder_uid,
    g.id as group_id,
    g.name as group_name,
    p.display_name,
    i.id as invite_id
  from auth.users me
  join public.profiles p
    on p.phone = (select phone from auth.users where id = auth.uid())
    and p.is_placeholder = true
    and p.claimed_at is null
  join public.invites i
    on i.placeholder_user_id = p.id
    and i.used_at is null
    and i.expires_at > now()
  join public.groups g on g.id = i.group_id
  where me.id = auth.uid()
    and me.phone is not null;
$$;

revoke all on function public.discover_pending_placeholders() from public, anon;
grant execute on function public.discover_pending_placeholders() to authenticated;

create or replace function public.get_placeholder_history_summary(
  p_placeholder_uid uuid
) returns jsonb
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_phone text;
  v_placeholder_phone text;
  v_member_id uuid;
  v_group_id uuid;
  v_fine_count int;
  v_vote_count int;
  v_event_count int;
begin
  if v_actor is null then raise exception 'get_placeholder_history_summary: not_authenticated'; end if;

  select phone into v_actor_phone from auth.users where id = v_actor;
  select phone into v_placeholder_phone from public.profiles
    where id = p_placeholder_uid and is_placeholder = true and claimed_at is null;
  if v_placeholder_phone is null then
    raise exception 'get_placeholder_history_summary: not_a_placeholder';
  end if;
  if v_actor_phone is null or v_actor_phone <> v_placeholder_phone then
    raise exception 'get_placeholder_history_summary: phone_mismatch';
  end if;

  select id, group_id into v_member_id, v_group_id
  from public.group_members where user_id = p_placeholder_uid limit 1;

  -- fines is user-id-based (placeholder uid).
  select count(*) into v_fine_count from public.fines
    where user_id = p_placeholder_uid;

  -- vote_casts is member-id-based (uses group_members.id, not user_id).
  select count(*) into v_vote_count from public.vote_casts
    where member_id = v_member_id;

  -- system_events: member-id-based atoms for the placeholder's membership.
  select count(*) into v_event_count from public.system_events
    where member_id = v_member_id;

  return jsonb_build_object(
    'group_id',     v_group_id,
    'member_id',    v_member_id,
    'fine_count',   coalesce(v_fine_count, 0),
    'vote_count',   coalesce(v_vote_count, 0),
    'event_count',  coalesce(v_event_count, 0)
  );
end$$;

revoke all on function public.get_placeholder_history_summary(uuid) from public, anon;
grant execute on function public.get_placeholder_history_summary(uuid) to authenticated;
