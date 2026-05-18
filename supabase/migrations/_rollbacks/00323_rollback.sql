-- Rollback for mig 00323: restore the 'members.invite' slug.
-- WARNING: with the original slug the function will always 403 even for
-- legitimate admins, because that slug doesn't exist in groups.roles
-- jsonb. Only roll back as part of reverting the full placeholder
-- feature.

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

  if not public.has_permission(p_group_id, p_actor_user_id, 'members.invite') then
    raise exception 'finalize_placeholder_member: actor % lacks members.invite on %', p_actor_user_id, p_group_id;
  end if;

  if exists (
    select 1 from public.profiles
    where phone = p_phone_e164
      and (is_placeholder = false or claimed_at is not null)
  ) then
    raise exception 'finalize_placeholder_member: phone % belongs to a real user', p_phone_e164;
  end if;

  insert into public.profiles
    (id, display_name, phone, is_placeholder, claimed_at)
  values
    (p_placeholder_user_id, p_display_name, p_phone_e164, true, null);

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
