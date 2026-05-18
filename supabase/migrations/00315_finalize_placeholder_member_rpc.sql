-- Mig 00315: finalize_placeholder_member RPC.
--
-- Called by the create-placeholder-member edge function AFTER it has used
-- the Supabase Admin API to create the placeholder auth.users row. This RPC
-- runs the rest atomically:
--   1. Insert profiles (is_placeholder=true, phone, display_name).
--   2. Insert group_members (joined_via='placeholder', active=true, next turn_order).
--   3. Insert invites with claim_token_hash + placeholder_user_id.
--   4. record_system_event(member.placeholder_created).
--   5. Return the raw claim_token (returned to edge function — never stored plaintext).
--
-- SECURITY: SECURITY DEFINER. Re-checks permission p_actor has
-- 'members.invite' on p_group_id as defense in depth — the edge function
-- already checked but RPC must be independently safe.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §9.2

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

  -- Defense-in-depth permission check.
  if not public.has_permission(p_group_id, p_actor_user_id, 'members.invite') then
    raise exception 'finalize_placeholder_member: actor % lacks members.invite on %', p_actor_user_id, p_group_id;
  end if;

  -- Reject if a real (non-placeholder or already-claimed) profile owns this phone.
  if exists (
    select 1 from public.profiles
    where phone = p_phone_e164
      and (is_placeholder = false or claimed_at is not null)
  ) then
    raise exception 'finalize_placeholder_member: phone % belongs to a real user', p_phone_e164;
  end if;

  -- Profile.
  insert into public.profiles
    (id, display_name, phone, is_placeholder, claimed_at)
  values
    (p_placeholder_user_id, p_display_name, p_phone_e164, true, null);

  -- group_members at the end of the rotation.
  select coalesce(max(turn_order), 0) + 1 into v_turn
  from public.group_members where group_id = p_group_id;

  insert into public.group_members
    (group_id, user_id, turn_order, joined_via, active)
  values
    (p_group_id, p_placeholder_user_id, v_turn, 'placeholder', true)
  returning id into v_member_id;

  -- Invite with claim token.
  insert into public.invites
    (group_id, invited_by, phone_e164, claim_token_hash,
     placeholder_user_id, expires_at)
  values
    (p_group_id, p_actor_user_id, p_phone_e164, v_claim_token_hash,
     p_placeholder_user_id, now() + interval '30 days')
  returning id into v_invite_id;

  -- Atom.
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
