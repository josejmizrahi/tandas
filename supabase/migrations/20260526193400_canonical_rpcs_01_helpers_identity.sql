-- §0. Helpers internos
create or replace function public.record_system_event(
  p_group_id    uuid,
  p_event_type  text,
  p_entity_kind text default null,
  p_entity_id   uuid default null,
  p_summary     text default null,
  p_payload     jsonb default '{}'::jsonb
)
returns table (id bigint, uuid_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_uuid uuid;
begin
  insert into public.group_events (
    group_id, actor_user_id, event_type, entity_kind, entity_id, summary, payload
  ) values (
    p_group_id, auth.uid(), p_event_type, p_entity_kind, p_entity_id, p_summary, coalesce(p_payload, '{}'::jsonb)
  )
  returning group_events.id, group_events.uuid_id into v_id, v_uuid;

  return query select v_id, v_uuid;
end;
$$;

create or replace function public.assert_member_of_group(p_group_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_membership_id uuid;
begin
  select id into v_membership_id
  from public.group_memberships
  where group_id = p_group_id
    and user_id = auth.uid()
    and status = 'active';
  if v_membership_id is null then
    raise exception 'caller is not an active member of group %', p_group_id
      using errcode = '42501';
  end if;
  return v_membership_id;
end;
$$;

create or replace function public.assert_permission(p_group_id uuid, p_permission text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_group_permission(p_group_id, p_permission) then
    raise exception 'caller lacks permission % in group %', p_permission, p_group_id
      using errcode = '42501';
  end if;
end;
$$;

-- §1. Identity & Membership
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

  v_code       := upper(substring(encode(gen_random_bytes(8), 'hex') for 8));
  v_token_hash := encode(digest(v_code || p_group_id::text, 'sha256'), 'hex');

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

  v_token_hash := encode(digest(upper(p_code) || v_invite.group_id::text, 'sha256'), 'hex');
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

create or replace function public.request_membership(
  p_group_id uuid,
  p_message  text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_membership uuid; v_visibility text;
begin
  if auth.uid() is null then raise exception 'must be authenticated'; end if;
  select visibility into v_visibility from public.groups where id = p_group_id;
  if v_visibility not in ('public','unlisted') then
    raise exception 'group is not open to membership requests';
  end if;

  insert into public.group_memberships (group_id, user_id, status, joined_via, metadata)
  values (p_group_id, auth.uid(), 'requested', 'admin_add', jsonb_build_object('message', p_message))
  on conflict (group_id, user_id) do update set status = 'requested'
  returning id into v_membership;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  values (p_group_id, v_membership, auth.uid(), 'requested', p_message);

  perform public.record_system_event(
    p_group_id, 'member.requested', 'membership', v_membership,
    'Solicitud de pertenencia', jsonb_build_object('message', p_message)
  );

  return v_membership;
end;
$$;

create or replace function public.set_membership_state(
  p_membership_id uuid,
  p_new_state     text,
  p_reason        text default null,
  p_until         timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_m public.group_memberships%rowtype;
  v_is_self boolean;
begin
  select * into v_m from public.group_memberships where id = p_membership_id for update;
  if v_m.id is null then raise exception 'membership not found'; end if;
  v_is_self := (v_m.user_id = auth.uid());

  if p_new_state not in ('active','suspended','left','banned','requested','invited') then
    raise exception 'invalid membership state %', p_new_state;
  end if;

  if p_new_state = 'left' then
    if not (v_is_self or public.has_group_permission(v_m.group_id, 'members.remove')) then
      raise exception 'caller cannot move membership to left';
    end if;
  elsif p_new_state = 'suspended' then
    perform public.assert_permission(v_m.group_id, 'members.suspend');
  elsif p_new_state = 'banned' then
    perform public.assert_permission(v_m.group_id, 'members.remove');
  else
    perform public.assert_permission(v_m.group_id, 'members.update');
  end if;

  update public.group_memberships
     set status = p_new_state,
         suspended_until = case when p_new_state='suspended' then p_until else null end,
         suspended_reason = case when p_new_state='suspended' then p_reason else suspended_reason end,
         left_at = case when p_new_state in ('left','banned') then now() else left_at end,
         left_reason = case when p_new_state in ('left','banned') then p_reason else left_reason end
   where id = p_membership_id;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  values (v_m.group_id, p_membership_id, auth.uid(),
          case p_new_state
            when 'suspended' then 'suspended'
            when 'active'    then 'reactivated'
            when 'left'      then 'left'
            when 'banned'    then 'banned'
            else 'other'
          end,
          p_reason);

  if p_new_state in ('left','banned','suspended') then
    update public.group_mandates
       set status = 'revoked', revoked_at = now(), revoked_reason = 'member_state_change'
     where representative_membership_id = p_membership_id and status = 'active';
  end if;

  perform public.record_system_event(
    v_m.group_id, 'member.state_changed', 'membership', p_membership_id,
    'Cambio de estado de membresía',
    jsonb_build_object('to', p_new_state, 'reason', p_reason)
  );
end;
$$;

create or replace function public.leave_group(p_group_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_membership uuid;
begin
  select id into v_membership from public.group_memberships
   where group_id = p_group_id and user_id = auth.uid() and status = 'active';
  if v_membership is null then raise exception 'no active membership to leave'; end if;
  perform public.set_membership_state(v_membership, 'left', p_reason, null);
end;
$$;

create or replace function public.confirm_provisional(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_m public.group_memberships%rowtype;
begin
  select * into v_m from public.group_memberships where id = p_membership_id for update;
  if v_m.id is null then raise exception 'membership not found'; end if;
  perform public.assert_permission(v_m.group_id, 'members.update');
  if v_m.membership_type <> 'provisional' then
    raise exception 'membership is not provisional';
  end if;

  update public.group_memberships
     set membership_type = 'member', confirmed_at = now()
   where id = p_membership_id;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  values (v_m.group_id, p_membership_id, auth.uid(), 'confirmed', null);

  perform public.record_system_event(
    v_m.group_id, 'member.confirmed', 'membership', p_membership_id,
    'Provisional confirmado', '{}'::jsonb
  );
end;
$$;
