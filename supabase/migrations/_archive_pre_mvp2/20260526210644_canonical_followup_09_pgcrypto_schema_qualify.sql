-- pgcrypto vive en `extensions`; las RPCs con `set search_path = public`
-- no lo encuentran. Re-apply invite_member + accept_invite con prefijo
-- extensions.* en gen_random_bytes y digest.

create or replace function public.invite_member(
  p_group_id          uuid,
  p_email             text default null,
  p_phone             text default null,
  p_role_key          text default null,
  p_membership_type   text default 'member',
  p_message           text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite_id  uuid;
  v_code       text;
  v_token_hash text;
  v_user_id    uuid;
begin
  perform public.assert_permission(p_group_id, 'members.invite');
  if p_email is null and p_phone is null then
    raise exception 'invite requires email or phone';
  end if;

  v_code       := upper(substring(encode(extensions.gen_random_bytes(8), 'hex') for 8));
  v_token_hash := encode(extensions.digest(v_code || p_group_id::text, 'sha256'), 'hex');

  select id into v_user_id from public.profiles
   where (p_phone is not null and lower(coalesce(phone, '')) = lower(p_phone))
   limit 1;

  insert into public.group_invites (
    group_id, email, phone, invited_user_id, invited_by,
    status, token_hash, code, expires_at, metadata
  ) values (
    p_group_id, p_email, p_phone, v_user_id, auth.uid(),
    'pending', v_token_hash, v_code, now() + interval '14 days',
    jsonb_build_object('message', p_message, 'role_key', p_role_key, 'membership_type', p_membership_type)
  )
  returning id into v_invite_id;

  perform public.record_system_event(
    p_group_id, 'member.invited', 'invite', v_invite_id,
    'Invitación creada',
    jsonb_build_object('email', p_email, 'phone', p_phone)
  );

  insert into public.notifications_outbox (group_id, recipient_user_id, category, payload)
  select p_group_id, v_user_id, 'member.invited',
         jsonb_build_object('invite_id', v_invite_id, 'group_id', p_group_id, 'code', v_code)
  where v_user_id is not null;

  return v_invite_id;
end;
$$;

create or replace function public.accept_invite(p_code text)
returns table (group_id uuid, membership_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite      public.group_invites%rowtype;
  v_token_hash  text;
  v_membership  uuid;
  v_existing_id uuid;
begin
  if auth.uid() is null then raise exception 'must be authenticated'; end if;

  select * into v_invite from public.group_invites
   where code = upper(p_code) and status = 'pending'
   limit 1;
  if v_invite.id is null then raise exception 'invite not found or already used'; end if;
  if v_invite.expires_at is not null and v_invite.expires_at < now() then
    update public.group_invites set status = 'expired' where id = v_invite.id;
    raise exception 'invite expired';
  end if;

  v_token_hash := encode(extensions.digest(upper(p_code) || v_invite.group_id::text, 'sha256'), 'hex');
  if v_token_hash <> v_invite.token_hash then
    raise exception 'invite token mismatch';
  end if;

  select id into v_existing_id from public.group_memberships
   where group_id = v_invite.group_id and user_id = auth.uid();

  if v_existing_id is not null then
    update public.group_memberships
       set status = 'active', joined_at = coalesce(joined_at, now()), confirmed_at = now()
     where id = v_existing_id;
    v_membership := v_existing_id;
  elsif v_invite.placeholder_membership_id is not null then
    update public.group_memberships
       set user_id = auth.uid(), status = 'active',
           joined_at = now(), confirmed_at = now(), joined_via = 'placeholder_claim'
     where id = v_invite.placeholder_membership_id
     returning id into v_membership;
  else
    insert into public.group_memberships (group_id, user_id, status, joined_at, joined_via)
    values (v_invite.group_id, auth.uid(), 'active', now(), 'invite_code')
    returning id into v_membership;
  end if;

  insert into public.group_membership_events (
    group_id, membership_id, actor_user_id, event_type, reason
  ) values (v_invite.group_id, v_membership, auth.uid(), 'joined', 'invite_accepted');

  update public.group_invites
     set status = 'accepted', accepted_at = now(), invited_user_id = auth.uid()
   where id = v_invite.id;

  perform public.record_system_event(
    v_invite.group_id, 'member.joined', 'membership', v_membership,
    'Miembro aceptó la invitación', '{}'::jsonb
  );

  return query select v_invite.group_id, v_membership;
end;
$$;
