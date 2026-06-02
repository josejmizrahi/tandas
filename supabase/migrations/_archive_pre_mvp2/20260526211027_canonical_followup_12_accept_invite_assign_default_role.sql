-- Bug: accept_invite no asignaba rol al nuevo miembro. Como las baseline
-- permissions (settlement.record, expense.record, rsvp.submit, etc.) cuelgan
-- del rol default 'member', el nuevo miembro entraba al grupo sin poder
-- hacer nada. Fix: al cierre de accept_invite, si el membership no tiene
-- roles, asignar el is_default=true del grupo.

create or replace function public.accept_invite(p_code text)
returns table (group_id uuid, membership_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite       public.group_invites%rowtype;
  v_token_hash   text;
  v_membership   uuid;
  v_existing_id  uuid;
  v_default_role uuid;
  v_has_role     int;
begin
  if auth.uid() is null then raise exception 'must be authenticated'; end if;

  select * into v_invite from public.group_invites gi
   where gi.code = upper(p_code) and gi.status = 'pending'
   limit 1;
  if v_invite.id is null then raise exception 'invite not found or already used'; end if;
  if v_invite.expires_at is not null and v_invite.expires_at < now() then
    update public.group_invites gi set status = 'expired' where gi.id = v_invite.id;
    raise exception 'invite expired';
  end if;

  v_token_hash := encode(extensions.digest(upper(p_code) || v_invite.group_id::text, 'sha256'), 'hex');
  if v_token_hash <> v_invite.token_hash then
    raise exception 'invite token mismatch';
  end if;

  select gm.id into v_existing_id from public.group_memberships gm
   where gm.group_id = v_invite.group_id and gm.user_id = auth.uid();

  if v_existing_id is not null then
    update public.group_memberships gm
       set status = 'active', joined_at = coalesce(gm.joined_at, now()), confirmed_at = now()
     where gm.id = v_existing_id;
    v_membership := v_existing_id;
  elsif v_invite.placeholder_membership_id is not null then
    update public.group_memberships gm
       set user_id = auth.uid(), status = 'active',
           joined_at = now(), confirmed_at = now(), joined_via = 'placeholder_claim'
     where gm.id = v_invite.placeholder_membership_id
     returning gm.id into v_membership;
  else
    insert into public.group_memberships (group_id, user_id, status, joined_at, joined_via)
    values (v_invite.group_id, auth.uid(), 'active', now(), 'invite_code')
    returning id into v_membership;
  end if;

  -- Auto-assign default role if member has none yet.
  select count(*) into v_has_role
    from public.group_member_roles
   where membership_id = v_membership;
  if v_has_role = 0 then
    select id into v_default_role
      from public.group_roles
     where group_id = v_invite.group_id and is_default = true
     limit 1;
    if v_default_role is not null then
      insert into public.group_member_roles (membership_id, role_id, assigned_by)
      values (v_membership, v_default_role, auth.uid())
      on conflict do nothing;
    end if;
  end if;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  values (v_invite.group_id, v_membership, auth.uid(), 'joined', 'invite_accepted');

  update public.group_invites gi
     set status = 'accepted', accepted_at = now(), invited_user_id = auth.uid()
   where gi.id = v_invite.id;

  perform public.record_system_event(
    v_invite.group_id, 'member.joined', 'membership', v_membership,
    'Miembro aceptó la invitación', '{}'::jsonb
  );

  group_id := v_invite.group_id;
  membership_id := v_membership;
  return next;
  return;
end;
$$;
