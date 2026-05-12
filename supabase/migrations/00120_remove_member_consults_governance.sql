-- 00120 — `remove_member` (00115) now routes through `resolve_governance`
-- (00111). Before this fix the RPC checked is_group_admin directly,
-- which bypassed the `member.remove` group_policy that every group has
-- via seed_default_group_policies. A group with policy_type=vote_required
-- could still get a member removed by an admin without the vote running.
--
-- The new shape:
--   1. resolve_governance(group, actor, 'member.remove', { user_id })
--      returns `decision` — 'allowed' / 'vote_required' / 'admin_only' /
--      'denied'.
--   2. 'allowed' or 'admin_only' (when has_permission already passed) →
--      proceed with the soft-delete + memberLeft emit.
--   3. 'vote_required' → raise a clear exception with the vote
--      requirements so iOS knows to start a `member_removal` vote
--      instead. The vote-trigger path (remove_member_on_removal_pass)
--      already handles the post-resolution cleanup.
--   4. 'denied' or 'admin_only' (without permission) → raise forbidden.
--
-- Self-removal guard stays — `leave_group` is the supported self path.

create or replace function public.remove_member(
  p_group_id uuid,
  p_user_id  uuid,
  p_reason   text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid           uuid := auth.uid();
  v_member_id     uuid;
  v_decision      jsonb;
  v_decision_type text;
  v_quorum        int;
  v_threshold     int;
  v_duration      int;
begin
  if v_uid is null then
    raise exception 'auth required';
  end if;
  if v_uid = p_user_id then
    raise exception 'admins cannot remove themselves — use leave_group';
  end if;

  -- Governance gate. Self-membership is checked inside resolve_governance.
  v_decision := public.resolve_governance(
    p_group_id,
    v_uid,
    'member.remove',
    jsonb_build_object('user_id', p_user_id)
  );

  v_decision_type := v_decision->>'decision';

  if v_decision_type = 'vote_required' then
    v_quorum    := coalesce((v_decision->>'quorum_percent')::int,    50);
    v_threshold := coalesce((v_decision->>'threshold_percent')::int, 50);
    v_duration  := coalesce((v_decision->>'duration_hours')::int,    72);
    -- iOS reads this message + the JSON payload via the SUPABASE error
    -- detail string. The message stays human-readable; structured
    -- consumers can parse the payload.
    raise exception 'governance requires vote: %', v_decision::text;
  end if;

  if v_decision_type = 'denied' then
    raise exception 'governance denied: %', coalesce(v_decision->>'reason', 'no_policy');
  end if;

  if v_decision_type = 'admin_only' then
    -- resolve_governance already ran has_permission and decided the
    -- caller didn't have it. Surface as a clean forbidden.
    raise exception 'admin only';
  end if;

  -- decision is 'allowed' — proceed.
  select id into v_member_id
    from public.group_members
   where group_id = p_group_id
     and user_id  = p_user_id
     and active   = true;

  if v_member_id is null then
    raise exception 'target user is not an active member of this group';
  end if;

  perform public.record_system_event(
    p_group_id,
    'memberLeft',
    null,
    v_member_id,
    jsonb_build_object(
      'user_id',    p_user_id,
      'removed_by', v_uid,
      'reason',     coalesce(p_reason, 'admin_removed')
    )
  );

  update public.group_members
     set active     = false,
         updated_at = now()
   where id = v_member_id;
end;
$$;

comment on function public.remove_member(uuid, uuid, text) is
  'Admin removes another member. Routes through resolve_governance(member.remove) so policies (admin_only / vote_required / denied) are respected. vote_required raises an exception with the vote requirements — caller should start a member_removal vote via start_vote instead. Soft-delete + memberLeft emit on success (00115 + 00120).';
