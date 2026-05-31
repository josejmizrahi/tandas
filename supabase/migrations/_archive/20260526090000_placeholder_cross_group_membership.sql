-- A single placeholder (phone) can be a member of multiple groups.
--
-- Today `finalize_placeholder_member` always INSERTs into profiles, which
-- panics when the placeholder user_id already exists (PK conflict). The
-- edge function's pre-check forbids the second-group case entirely with a
-- 409 duplicate_placeholder.
--
-- Doctrine: a phone = a person = one user_id. The same placeholder should
-- be addable to many groups (group_members.UNIQUE(group_id, user_id)
-- already permits this). Only block when re-adding to the SAME group.
--
-- Two changes:
--   1. Profile INSERT becomes `ON CONFLICT (id) DO NOTHING` so re-running
--      the RPC for an already-existing placeholder is a no-op for the
--      profile row but still inserts the new group_members + invite.
--   2. Add an explicit guard: if (group_id, user_id) already exists in
--      group_members, raise a clean error instead of relying on the
--      UNIQUE constraint to bubble a Postgres-y message.
--
-- Companion: supabase/functions/create-placeholder-member/index.ts now
-- detects the dupPlaceholder case and reuses its user_id (skipping the
-- auth.users createUser + profile delete steps) so the RPC sees the
-- existing placeholder_user_id and the profile insert no-ops.

create or replace function public.finalize_placeholder_member(
  p_placeholder_user_id uuid,
  p_group_id uuid,
  p_display_name text,
  p_phone_e164 text,
  p_actor_user_id uuid
) returns jsonb
language plpgsql security definer set search_path = public, pg_catalog, extensions
as $$
declare
  v_claim_token text := encode(gen_random_bytes(32), 'hex');
  v_claim_token_hash text := encode(
    digest(v_claim_token::bytea, 'sha256'), 'hex'
  );
  v_invite_id uuid;
  v_member_id uuid;
  v_turn int;
begin
  if p_placeholder_user_id is null
     or p_group_id is null
     or p_display_name is null or length(trim(p_display_name)) = 0
     or p_phone_e164 is null or length(trim(p_phone_e164)) = 0
     or p_actor_user_id is null then
    raise exception 'finalize_placeholder_member: all args required';
  end if;

  if not public.has_permission(p_group_id, p_actor_user_id, 'modifyMembers') then
    raise exception 'finalize_placeholder_member: actor % lacks modifyMembers on %', p_actor_user_id, p_group_id;
  end if;

  -- Reject if a real (non-placeholder or already-claimed) profile owns this phone.
  if exists (
    select 1 from public.profiles
    where phone = p_phone_e164
      and (is_placeholder = false or claimed_at is not null)
  ) then
    raise exception 'finalize_placeholder_member: phone % belongs to a real user', p_phone_e164;
  end if;

  -- Guard: same placeholder + same group = already a member, nothing to do.
  if exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = p_placeholder_user_id
  ) then
    raise exception 'finalize_placeholder_member: % is already a member of %', p_placeholder_user_id, p_group_id;
  end if;

  -- Profile: idempotent. First insertion creates the row; subsequent
  -- group additions for the same placeholder reuse it.
  insert into public.profiles
    (id, display_name, phone, is_placeholder, claimed_at)
  values
    (p_placeholder_user_id, p_display_name, p_phone_e164, true, null)
  on conflict (id) do nothing;

  select coalesce(max(turn_order), 0) + 1 into v_turn
  from public.group_members where group_id = p_group_id;

  insert into public.group_members
    (group_id, user_id, turn_order, joined_via, active)
  values
    (p_group_id, p_placeholder_user_id, v_turn, 'placeholder', true)
  returning id into v_member_id;

  insert into public.invites
    (group_id, invited_by, phone_e164, claim_token_hash,
     placeholder_user_id, expires_at)
  values
    (p_group_id, p_actor_user_id, p_phone_e164, v_claim_token_hash,
     p_placeholder_user_id, now() + interval '30 days')
  returning id into v_invite_id;

  perform public.record_system_event(
    p_group_id    := p_group_id,
    p_event_type  := 'member.placeholder_created',
    p_resource_id := null,
    p_member_id   := v_member_id,
    p_payload     := jsonb_build_object(
      'placeholder_user_id', p_placeholder_user_id,
      'invite_id',           v_invite_id,
      'phone_e164',          p_phone_e164,
      'display_name',        p_display_name,
      'actor_user_id',       p_actor_user_id
    )
  );

  return jsonb_build_object(
    'claim_token',         v_claim_token,
    'invite_id',           v_invite_id,
    'member_id',           v_member_id,
    'placeholder_user_id', p_placeholder_user_id,
    'turn_order',          v_turn
  );
end$$;

revoke all on function public.finalize_placeholder_member(uuid, uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.finalize_placeholder_member(uuid, uuid, text, text, uuid) to service_role;

comment on function public.finalize_placeholder_member(uuid, uuid, text, text, uuid) is
  'Adds a placeholder to a group. Idempotent on the profile row so the SAME placeholder can be added to multiple groups (a phone = a person, can live in N groups). Rejects: (a) phone owned by real user, (b) caller lacks modifyMembers, (c) placeholder already in this group. Mig placeholder_cross_group_membership 2026-05-26.';
