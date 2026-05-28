-- ============================================================================
-- CanonicalRPCs.sql — bodies de todas las RPCs canónicas (DRAFT)
-- ============================================================================
--
-- Anexo SQL de `Plans/Active/CanonicalSchema_RPCs.md`.
--
-- Se aplica DESPUÉS de `CanonicalReset.sql`, `CanonicalSchema.sql`,
-- `CanonicalRLS.sql`. Cada RPC sigue la forma estándar del catálogo:
--   * language plpgsql security definer
--   * set search_path = public
--   * permission gate al inicio
--   * mutación + memoria + side effects
--   * idempotencia via client_id cuando aplica
--
-- Notas de implementación:
--   * `record_system_event(...)` se usa como helper interno para escribir a
--     `group_events`. Si una RPC necesita escribir varios eventos, llama a
--     este helper por cada uno (no inserta inline).
--   * Las RPCs que mutan obligaciones/settlements/votos usan `for update`
--     en las filas antes de leer estados derivados.
--   * Las RPCs públicas que aún no se exponen en iOS V1 (request_membership,
--     delete_and_export_my_data, request_otp, verify_otp) quedan como stubs
--     con cuerpo mínimo correcto, no como TODO.
-- ============================================================================

-- ============================================================================
-- §0. Helpers internos
-- ============================================================================

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

-- ============================================================================
-- §1. Identity & Membership
-- ============================================================================
-- create_group already defined in CanonicalSchema.sql §19.

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
   where (p_email is not null and lower(coalesce(phone, '')) = lower(coalesce(p_phone, '')))
      or false
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

-- ============================================================================
-- §2. Purpose
-- ============================================================================

create or replace function public.set_group_purpose(
  p_group_id uuid,
  p_kind     text,
  p_body     text,
  p_visibility text default 'members'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'purpose.set');

  update public.group_purposes
     set status = 'archived'
   where group_id = p_group_id and kind = p_kind and status = 'active';

  insert into public.group_purposes (group_id, kind, body, visibility, created_by)
  values (p_group_id, p_kind, p_body, p_visibility, auth.uid())
  returning id into v_id;

  if p_kind = 'declared' then
    update public.groups set purpose_summary = p_body where id = p_group_id;
  end if;

  perform public.record_system_event(
    p_group_id, 'purpose.set', 'purpose', v_id,
    'Propósito actualizado',
    jsonb_build_object('kind', p_kind)
  );
  return v_id;
end;
$$;

create or replace function public.archive_group_purpose(p_purpose_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_purposes where id = p_purpose_id;
  if v_group is null then raise exception 'purpose not found'; end if;
  perform public.assert_permission(v_group, 'purpose.set');
  update public.group_purposes set status = 'archived' where id = p_purpose_id;

  perform public.record_system_event(
    v_group, 'purpose.archived', 'purpose', p_purpose_id, 'Propósito archivado', '{}'::jsonb
  );
end;
$$;

-- ============================================================================
-- §3. Roles & Permissions
-- ============================================================================

create or replace function public.create_custom_role(
  p_group_id        uuid,
  p_key             text,
  p_name            text,
  p_description     text,
  p_permission_keys text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_role_id uuid; k text;
begin
  perform public.assert_permission(p_group_id, 'roles.manage');
  insert into public.group_roles (group_id, key, name, description, is_system, is_default)
  values (p_group_id, p_key, p_name, p_description, false, false)
  returning id into v_role_id;

  foreach k in array coalesce(p_permission_keys, ARRAY[]::text[])
  loop
    insert into public.group_role_permissions (role_id, permission_key) values (v_role_id, k)
    on conflict do nothing;
  end loop;

  perform public.record_system_event(
    p_group_id, 'role.created', 'role', v_role_id, 'Rol creado',
    jsonb_build_object('key', p_key)
  );
  return v_role_id;
end;
$$;

create or replace function public.update_role_permissions(
  p_role_id         uuid,
  p_permission_keys text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid; v_is_system boolean;
begin
  select group_id, is_system into v_group, v_is_system from public.group_roles where id = p_role_id;
  if v_group is null then raise exception 'role not found'; end if;
  if v_is_system then raise exception 'cannot mutate system role permissions'; end if;
  perform public.assert_permission(v_group, 'roles.manage');

  delete from public.group_role_permissions
   where role_id = p_role_id
     and permission_key not in (select unnest(coalesce(p_permission_keys, ARRAY[]::text[])));

  insert into public.group_role_permissions (role_id, permission_key)
  select p_role_id, k from unnest(coalesce(p_permission_keys, ARRAY[]::text[])) as k
  on conflict do nothing;

  perform public.record_system_event(
    v_group, 'role.permissions_updated', 'role', p_role_id, 'Permisos de rol actualizados', '{}'::jsonb
  );
end;
$$;

create or replace function public.assign_role_to_member(
  p_membership_id uuid,
  p_role_id       uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_memberships where id = p_membership_id;
  if v_group is null then raise exception 'membership not found'; end if;
  perform public.assert_permission(v_group, 'roles.manage');

  insert into public.group_member_roles (membership_id, role_id, assigned_by)
  values (p_membership_id, p_role_id, auth.uid())
  on conflict do nothing;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, payload)
  values (v_group, p_membership_id, auth.uid(), 'role_assigned',
          jsonb_build_object('role_id', p_role_id));
end;
$$;

create or replace function public.revoke_role_from_member(
  p_membership_id uuid,
  p_role_id       uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid; v_remaining int;
begin
  select group_id into v_group from public.group_memberships where id = p_membership_id;
  if v_group is null then raise exception 'membership not found'; end if;
  perform public.assert_permission(v_group, 'roles.manage');

  select count(*) into v_remaining from public.group_member_roles
   where membership_id = p_membership_id and role_id <> p_role_id;
  if v_remaining = 0 then
    raise exception 'cannot revoke last role from member';
  end if;

  delete from public.group_member_roles
   where membership_id = p_membership_id and role_id = p_role_id;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, payload)
  values (v_group, p_membership_id, auth.uid(), 'role_revoked',
          jsonb_build_object('role_id', p_role_id));
end;
$$;

create or replace function public.list_member_permissions(
  p_group_id uuid,
  p_user_id  uuid default null
)
returns setof text
language sql
stable
security definer
set search_path = public
as $$
  select distinct grp.permission_key
  from public.group_memberships gm
  join public.group_member_roles gmr on gmr.membership_id = gm.id
  join public.group_role_permissions grp on grp.role_id = gmr.role_id
  where gm.group_id = p_group_id
    and gm.status = 'active'
    and gm.user_id = coalesce(p_user_id, auth.uid());
$$;

-- ============================================================================
-- §4. Mandates
-- ============================================================================

create or replace function public.grant_mandate(
  p_group_id                  uuid,
  p_representative_membership_id uuid,
  p_mandate_type              text,
  p_principal_type            text default 'group',
  p_principal_id              uuid default null,
  p_scope                     jsonb default '{}'::jsonb,
  p_ends_at                   timestamptz default null,
  p_source_decision_id        uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'mandates.grant');

  insert into public.group_mandates (
    group_id, principal_type, principal_id, representative_membership_id,
    mandate_type, scope, ends_at, source_decision_id, granted_by
  ) values (
    p_group_id, p_principal_type, p_principal_id, p_representative_membership_id,
    p_mandate_type, coalesce(p_scope, '{}'::jsonb), p_ends_at, p_source_decision_id, auth.uid()
  )
  returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'mandate.granted', 'mandate', v_id,
    'Mandato otorgado',
    jsonb_build_object('mandate_type', p_mandate_type, 'representative', p_representative_membership_id)
  );
  return v_id;
end;
$$;

create or replace function public.revoke_mandate(
  p_mandate_id uuid,
  p_reason     text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_mandates where id = p_mandate_id for update;
  if v_group is null then raise exception 'mandate not found'; end if;
  perform public.assert_permission(v_group, 'mandates.revoke');

  update public.group_mandates
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoked_reason = p_reason
   where id = p_mandate_id;

  perform public.record_system_event(
    v_group, 'mandate.revoked', 'mandate', p_mandate_id, 'Mandato revocado',
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.report_on_mandate(
  p_mandate_id uuid,
  p_summary    text,
  p_payload    jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_m public.group_mandates%rowtype;
begin
  select * into v_m from public.group_mandates where id = p_mandate_id;
  if v_m.id is null then raise exception 'mandate not found'; end if;
  if not exists (
    select 1 from public.group_memberships m
    where m.id = v_m.representative_membership_id and m.user_id = auth.uid()
  ) then
    raise exception 'only the mandate holder can report on it';
  end if;

  perform public.record_system_event(
    v_m.group_id, 'mandate.report', 'mandate', p_mandate_id, p_summary, coalesce(p_payload, '{}'::jsonb)
  );
end;
$$;

-- ============================================================================
-- §5. Rules
-- ============================================================================

create or replace function public.propose_rule(
  p_group_id  uuid,
  p_title     text,
  p_rule_type text,
  p_severity  int default 1,
  p_slug      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'rules.create');
  insert into public.group_rules (group_id, slug, title, rule_type, severity, status, created_by)
  values (p_group_id, p_slug, p_title, p_rule_type, p_severity, 'draft', auth.uid())
  returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'rule.proposed', 'rule', v_id, 'Regla propuesta',
    jsonb_build_object('title', p_title, 'type', p_rule_type)
  );
  return v_id;
end;
$$;

create or replace function public.publish_rule_version(
  p_rule_id            uuid,
  p_execution_mode     text,
  p_body               text default null,
  p_trigger_event_type text default null,
  p_condition_tree     jsonb default null,
  p_consequences       jsonb default null,
  p_shape_key          text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.group_rules%rowtype;
  v_next_version int;
  v_version_id uuid;
begin
  select * into v_rule from public.group_rules where id = p_rule_id for update;
  if v_rule.id is null then raise exception 'rule not found'; end if;
  perform public.assert_permission(v_rule.group_id, 'rules.publish');

  if p_execution_mode not in ('text','engine') then raise exception 'invalid execution_mode'; end if;
  if p_execution_mode = 'engine' then
    if p_shape_key is null or not exists (select 1 from public.rule_shapes_catalog where shape_key = p_shape_key) then
      raise exception 'engine rule needs valid shape_key';
    end if;
    if p_condition_tree is null or p_consequences is null then
      raise exception 'engine rule needs condition_tree and consequences';
    end if;
  end if;

  select coalesce(max(version), 0) + 1 into v_next_version
    from public.group_rule_versions where rule_id = p_rule_id;

  if v_rule.current_version_id is not null then
    update public.group_rule_versions
       set effective_until = now()
     where id = v_rule.current_version_id and effective_until is null;
  end if;

  insert into public.group_rule_versions (
    rule_id, version, execution_mode, body, trigger_event_type,
    condition_tree, consequences, shape_key, effective_from, published_by
  ) values (
    p_rule_id, v_next_version, p_execution_mode, p_body, p_trigger_event_type,
    p_condition_tree, p_consequences, p_shape_key, now(), auth.uid()
  )
  returning id into v_version_id;

  update public.group_rules
     set current_version_id = v_version_id, status = 'active'
   where id = p_rule_id;

  perform public.record_system_event(
    v_rule.group_id, 'rule.published', 'rule', p_rule_id,
    'Versión de regla publicada',
    jsonb_build_object('version', v_next_version, 'execution_mode', p_execution_mode)
  );
  return v_version_id;
end;
$$;

create or replace function public.archive_rule(p_rule_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_rule public.group_rules%rowtype;
begin
  select * into v_rule from public.group_rules where id = p_rule_id for update;
  if v_rule.id is null then raise exception 'rule not found'; end if;
  perform public.assert_permission(v_rule.group_id, 'rules.archive');

  update public.group_rules set status = 'archived' where id = p_rule_id;
  if v_rule.current_version_id is not null then
    update public.group_rule_versions set effective_until = now()
     where id = v_rule.current_version_id and effective_until is null;
  end if;

  perform public.record_system_event(
    v_rule.group_id, 'rule.archived', 'rule', p_rule_id, 'Regla archivada',
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.evaluate_rules_for_event(p_event_uuid_id uuid)
returns setof uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.group_events%rowtype;
  v_rv     public.group_rule_versions%rowtype;
  v_eval_id uuid;
  v_idem text;
begin
  select * into v_event from public.group_events where uuid_id = p_event_uuid_id;
  if v_event.id is null then raise exception 'event not found'; end if;

  for v_rv in
    select rv.* from public.group_rule_versions rv
    join public.group_rules r on r.current_version_id = rv.id
    where r.group_id = v_event.group_id
      and r.status = 'active'
      and rv.execution_mode = 'engine'
      and rv.trigger_event_type = v_event.event_type
  loop
    v_idem := p_event_uuid_id::text || '|' || v_rv.id::text;
    insert into public.group_rule_evaluations (
      rule_version_id, group_id, source_event_id, matched, consequences_emitted, idempotency_key
    ) values (
      v_rv.id, v_event.group_id, p_event_uuid_id, true,
      coalesce(v_rv.consequences, '[]'::jsonb), v_idem
    )
    on conflict (idempotency_key) do nothing
    returning id into v_eval_id;
    if v_eval_id is not null then return next v_eval_id; end if;
  end loop;
  return;
end;
$$;

-- ============================================================================
-- §6. Resources — envelope
-- ============================================================================

create or replace function public.create_resource(
  p_group_id        uuid,
  p_resource_type   text,
  p_name            text,
  p_subtype_payload jsonb default '{}'::jsonb,
  p_visibility      text default 'members',
  p_ownership_kind  text default 'group',
  p_series_id       uuid default null,
  p_metadata        jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_payload jsonb;
begin
  perform public.assert_permission(p_group_id, 'resources.create');
  v_payload := coalesce(p_subtype_payload, '{}'::jsonb);

  insert into public.group_resources (
    group_id, resource_type, name, visibility, ownership_kind, series_id, metadata, created_by
  ) values (
    p_group_id, p_resource_type, p_name, p_visibility, p_ownership_kind, p_series_id,
    coalesce(p_metadata, '{}'::jsonb), auth.uid()
  ) returning id into v_id;

  if p_resource_type = 'event' then
    insert into public.group_resource_events (
      resource_id, starts_at, ends_at, location, location_geo, capacity, host_membership_id, rsvp_deadline
    ) values (
      v_id,
      coalesce((v_payload->>'starts_at')::timestamptz, now() + interval '1 day'),
      nullif(v_payload->>'ends_at','')::timestamptz,
      v_payload->>'location',
      nullif(v_payload->'location_geo','null'),
      nullif(v_payload->>'capacity','')::int,
      nullif(v_payload->>'host_membership_id','')::uuid,
      nullif(v_payload->>'rsvp_deadline','')::timestamptz
    );
  elsif p_resource_type = 'fund' then
    insert into public.group_resource_funds (resource_id, fund_kind, currency, is_shared_pool, is_in_kind, threshold_target)
    values (
      v_id,
      coalesce(v_payload->>'fund_kind', 'pool'),
      coalesce(v_payload->>'currency', 'MXN'),
      coalesce((v_payload->>'is_shared_pool')::boolean, false),
      coalesce((v_payload->>'is_in_kind')::boolean, false),
      nullif(v_payload->>'threshold_target','')::numeric
    );
  elsif p_resource_type = 'slot' then
    insert into public.group_resource_slots (resource_id, slot_starts_at, slot_ends_at, assigned_membership_id)
    values (
      v_id,
      coalesce((v_payload->>'slot_starts_at')::timestamptz, now()),
      nullif(v_payload->>'slot_ends_at','')::timestamptz,
      nullif(v_payload->>'assigned_membership_id','')::uuid
    );
  elsif p_resource_type = 'space' then
    insert into public.group_resource_spaces (resource_id, address, geo, capacity, rules)
    values (
      v_id, v_payload->>'address', nullif(v_payload->'geo','null'),
      nullif(v_payload->>'capacity','')::int, v_payload->>'rules'
    );
  elsif p_resource_type = 'asset' then
    insert into public.group_resource_assets (
      resource_id, asset_kind, serial_number, current_value, current_value_unit, condition, custodian_membership_id
    ) values (
      v_id, v_payload->>'asset_kind', v_payload->>'serial_number',
      nullif(v_payload->>'current_value','')::numeric,
      v_payload->>'current_value_unit', v_payload->>'condition',
      nullif(v_payload->>'custodian_membership_id','')::uuid
    );
  elsif p_resource_type = 'right' then
    insert into public.group_resource_rights (
      resource_id, right_kind, holder_membership_id, expires_at, transferable, conditions
    ) values (
      v_id, v_payload->>'right_kind',
      nullif(v_payload->>'holder_membership_id','')::uuid,
      nullif(v_payload->>'expires_at','')::timestamptz,
      coalesce((v_payload->>'transferable')::boolean, false),
      v_payload->>'conditions'
    );
  end if;

  perform public.record_system_event(
    p_group_id, 'resource.created', 'resource', v_id,
    p_name,
    jsonb_build_object('resource_type', p_resource_type)
  );
  return v_id;
end;
$$;

create or replace function public.update_resource(
  p_resource_id     uuid,
  p_name            text default null,
  p_description     text default null,
  p_visibility      text default null,
  p_metadata        jsonb default null,
  p_subtype_payload jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.update');

  update public.group_resources
     set name        = coalesce(p_name, name),
         description = coalesce(p_description, description),
         visibility  = coalesce(p_visibility, visibility),
         metadata    = case when p_metadata is null then metadata else metadata || p_metadata end
   where id = p_resource_id;

  if p_subtype_payload is not null then
    if v_r.resource_type = 'event' then
      update public.group_resource_events
         set starts_at = coalesce(nullif(p_subtype_payload->>'starts_at','')::timestamptz, starts_at),
             ends_at   = coalesce(nullif(p_subtype_payload->>'ends_at','')::timestamptz, ends_at),
             location  = coalesce(p_subtype_payload->>'location', location),
             capacity  = coalesce(nullif(p_subtype_payload->>'capacity','')::int, capacity),
             host_membership_id = coalesce(nullif(p_subtype_payload->>'host_membership_id','')::uuid, host_membership_id),
             rsvp_deadline = coalesce(nullif(p_subtype_payload->>'rsvp_deadline','')::timestamptz, rsvp_deadline)
       where resource_id = p_resource_id;
    elsif v_r.resource_type = 'fund' then
      update public.group_resource_funds
         set fund_kind = coalesce(p_subtype_payload->>'fund_kind', fund_kind),
             currency  = coalesce(p_subtype_payload->>'currency', currency),
             is_shared_pool = coalesce((p_subtype_payload->>'is_shared_pool')::boolean, is_shared_pool),
             threshold_target = coalesce(nullif(p_subtype_payload->>'threshold_target','')::numeric, threshold_target)
       where resource_id = p_resource_id;
    end if;
  end if;

  perform public.record_system_event(
    v_r.group_id, 'resource.updated', 'resource', p_resource_id,
    'Recurso actualizado', '{}'::jsonb
  );
end;
$$;

create or replace function public.set_resource_ownership(
  p_resource_id        uuid,
  p_ownership_kind     text,
  p_owner_membership_id uuid default null,
  p_metadata           jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.transfer');

  update public.group_resources
     set ownership_kind = p_ownership_kind,
         owner_membership_id = p_owner_membership_id,
         ownership_metadata = coalesce(p_metadata, '{}'::jsonb)
   where id = p_resource_id;

  perform public.record_system_event(
    v_r.group_id, 'resource.ownership_changed', 'resource', p_resource_id,
    'Propiedad transferida',
    jsonb_build_object('to_kind', p_ownership_kind, 'to_member', p_owner_membership_id)
  );
end;
$$;

create or replace function public.archive_resource(p_resource_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_open int;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.archive');

  select count(*) into v_open from public.group_obligations
   where source_resource_id = p_resource_id and status in ('open','partially_settled');
  if v_open > 0 then raise exception 'resource has % open obligations', v_open; end if;

  update public.group_resources
     set status = 'archived', archived_at = now()
   where id = p_resource_id;

  perform public.record_system_event(
    v_r.group_id, 'resource.archived', 'resource', p_resource_id, 'Recurso archivado',
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

create or replace function public.revert_archive_resource(p_resource_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.update');
  update public.group_resources set status = 'active', archived_at = null where id = p_resource_id;

  perform public.record_system_event(
    v_r.group_id, 'resource.unarchived', 'resource', p_resource_id, 'Recurso reactivado',
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

-- ============================================================================
-- §7. Resource series & capabilities
-- ============================================================================

create or replace function public.create_resource_series(
  p_group_id        uuid,
  p_resource_type   text,
  p_cadence         text,
  p_pattern         jsonb default '{}'::jsonb,
  p_starts_on       date default null,
  p_ends_on         date default null,
  p_ritual_meaning  text default null,
  p_ritual_marker_kind text default null,
  p_template_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'resources.create');
  insert into public.group_resource_series (
    group_id, resource_type, cadence, pattern, starts_on, ends_on,
    ritual_meaning, ritual_marker_kind, template_payload, created_by
  ) values (
    p_group_id, p_resource_type, p_cadence,
    coalesce(p_pattern, '{}'::jsonb), p_starts_on, p_ends_on,
    p_ritual_meaning, p_ritual_marker_kind,
    coalesce(p_template_payload, '{}'::jsonb), auth.uid()
  )
  returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'resource_series.created', 'resource_series', v_id,
    'Serie creada',
    jsonb_build_object('cadence', p_cadence, 'resource_type', p_resource_type)
  );
  return v_id;
end;
$$;

create or replace function public.update_resource_series(
  p_series_id        uuid,
  p_pattern          jsonb default null,
  p_ritual_meaning   text  default null,
  p_ritual_marker_kind text default null,
  p_template_payload jsonb default null,
  p_ends_on          date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_resource_series where id = p_series_id for update;
  if v_group is null then raise exception 'series not found'; end if;
  perform public.assert_permission(v_group, 'resources.update');

  update public.group_resource_series
     set pattern             = coalesce(p_pattern, pattern),
         ritual_meaning      = coalesce(p_ritual_meaning, ritual_meaning),
         ritual_marker_kind  = coalesce(p_ritual_marker_kind, ritual_marker_kind),
         template_payload    = coalesce(p_template_payload, template_payload),
         ends_on             = coalesce(p_ends_on, ends_on)
   where id = p_series_id;

  perform public.record_system_event(
    v_group, 'resource_series.updated', 'resource_series', p_series_id, 'Serie actualizada', '{}'::jsonb
  );
end;
$$;

create or replace function public.enable_resource_capability(
  p_resource_id  uuid,
  p_capability_key text,
  p_config       jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_resources where id = p_resource_id;
  if v_group is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_group, 'resources.update');

  insert into public.group_resource_capabilities (resource_id, capability_key, enabled, config, enabled_by)
  values (p_resource_id, p_capability_key, true, coalesce(p_config, '{}'::jsonb), auth.uid())
  on conflict (resource_id, capability_key) do update
    set enabled = true, config = excluded.config, enabled_by = auth.uid();

  perform public.record_system_event(
    v_group, 'resource.capability_enabled', 'resource', p_resource_id, p_capability_key, '{}'::jsonb
  );
end;
$$;

create or replace function public.disable_resource_capability(
  p_resource_id    uuid,
  p_capability_key text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_resources where id = p_resource_id;
  if v_group is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_group, 'resources.update');

  update public.group_resource_capabilities
     set enabled = false
   where resource_id = p_resource_id and capability_key = p_capability_key;

  perform public.record_system_event(
    v_group, 'resource.capability_disabled', 'resource', p_resource_id, p_capability_key, '{}'::jsonb
  );
end;
$$;

-- ============================================================================
-- §8. Resource ops — bookings, RSVP, check-in
-- ============================================================================

create or replace function public.book_resource(
  p_resource_id uuid,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz default null,
  p_reason      text default null,
  p_client_id   text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_membership uuid; v_id uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'bookings.create');
  v_membership := public.assert_member_of_group(v_r.group_id);

  if p_client_id is not null then
    select id into v_id from public.group_resource_bookings
     where group_id = v_r.group_id and metadata->>'client_id' = p_client_id;
    if v_id is not null then return v_id; end if;
  end if;

  insert into public.group_resource_bookings (
    group_id, resource_id, booked_by_membership_id, starts_at, ends_at, status, reason, metadata
  ) values (
    v_r.group_id, p_resource_id, v_membership, p_starts_at, p_ends_at, 'confirmed',
    p_reason,
    case when p_client_id is null then '{}'::jsonb else jsonb_build_object('client_id', p_client_id) end
  )
  returning id into v_id;

  perform public.record_system_event(
    v_r.group_id, 'booking.created', 'booking', v_id, p_reason,
    jsonb_build_object('resource_id', p_resource_id, 'starts_at', p_starts_at)
  );
  return v_id;
end;
$$;

create or replace function public.cancel_booking(
  p_booking_id uuid,
  p_reason     text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_b public.group_resource_bookings%rowtype; v_new uuid; v_is_owner boolean;
begin
  select * into v_b from public.group_resource_bookings where id = p_booking_id;
  if v_b.id is null then raise exception 'booking not found'; end if;
  v_is_owner := exists (
    select 1 from public.group_memberships m
    where m.id = v_b.booked_by_membership_id and m.user_id = auth.uid()
  );
  if not v_is_owner and not public.has_group_permission(v_b.group_id, 'bookings.cancel') then
    raise exception 'caller cannot cancel this booking';
  end if;

  insert into public.group_resource_bookings (
    group_id, resource_id, booked_by_membership_id, starts_at, ends_at, status, reason, metadata
  ) values (
    v_b.group_id, v_b.resource_id, v_b.booked_by_membership_id, v_b.starts_at, v_b.ends_at,
    'cancelled', p_reason,
    jsonb_build_object('cancels_booking_id', p_booking_id)
  ) returning id into v_new;

  perform public.record_system_event(
    v_b.group_id, 'booking.cancelled', 'booking', p_booking_id, p_reason, '{}'::jsonb
  );
  return v_new;
end;
$$;

create or replace function public.submit_rsvp(
  p_resource_id uuid,
  p_rsvp_status text,
  p_note        text default null,
  p_client_id   text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_m uuid; v_id uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'rsvp.submit');
  v_m := public.assert_member_of_group(v_r.group_id);

  insert into public.group_rsvp_actions (
    group_id, resource_id, membership_id, user_id, rsvp_status, note
  ) values (
    v_r.group_id, p_resource_id, v_m, auth.uid(), p_rsvp_status, p_note
  )
  returning id into v_id;

  perform public.record_system_event(
    v_r.group_id, 'rsvp.submitted', 'resource', p_resource_id, p_rsvp_status,
    jsonb_build_object('membership_id', v_m, 'rsvp_status', p_rsvp_status)
  );
  return v_id;
end;
$$;

create or replace function public.submit_check_in(
  p_resource_id        uuid,
  p_check_in_method    text default 'self',
  p_location_verified  boolean default null,
  p_client_id          text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_m uuid; v_id uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'check_in.submit');
  v_m := public.assert_member_of_group(v_r.group_id);

  insert into public.group_check_in_actions (
    group_id, resource_id, membership_id, check_in_method, location_verified
  ) values (
    v_r.group_id, p_resource_id, v_m, p_check_in_method, p_location_verified
  ) returning id into v_id;

  perform public.record_system_event(
    v_r.group_id, 'check_in.submitted', 'resource', p_resource_id, p_check_in_method, '{}'::jsonb
  );
  return v_id;
end;
$$;

create or replace function public.mark_no_show(
  p_resource_id   uuid,
  p_membership_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_event_uuid uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.update');

  select uuid_id into v_event_uuid from public.record_system_event(
    v_r.group_id, 'check_in.missed', 'resource', p_resource_id,
    'Miembro no se presentó',
    jsonb_build_object('membership_id', p_membership_id)
  );
  perform public.evaluate_rules_for_event(v_event_uuid);
end;
$$;

-- ============================================================================
-- §9. Money 2.0
-- ============================================================================

create or replace function public.record_expense(
  p_group_id            uuid,
  p_resource_id         uuid,
  p_amount              numeric,
  p_unit                text,
  p_paid_by_membership_id uuid,
  p_description         text default null,
  p_split_mode          text default 'even',
  p_split_breakdown     jsonb default null,
  p_in_kind             boolean default false,
  p_client_id           text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tx_id uuid;
  v_resource_group uuid;
  v_n int;
  v_per numeric;
  v_member jsonb;
begin
  perform public.assert_permission(p_group_id, 'expense.record');
  if p_resource_id is not null then
    select group_id into v_resource_group from public.group_resources where id = p_resource_id;
    if v_resource_group is distinct from p_group_id then
      raise exception 'resource % not in group %', p_resource_id, p_group_id;
    end if;
  end if;
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  if p_client_id is not null then
    select id into v_tx_id from public.group_resource_transactions
     where group_id = p_group_id and client_id = p_client_id;
    if v_tx_id is not null then return v_tx_id; end if;
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, paid_by_membership_id,
    amount, unit, source_resource_id, source_entity_kind,
    split_breakdown, split_mode, in_kind, description, client_id, recorded_by
  ) values (
    p_group_id, p_resource_id, 'expense', p_paid_by_membership_id,
    p_amount, p_unit, p_resource_id, 'manual',
    p_split_breakdown, p_split_mode, p_in_kind, p_description, p_client_id, auth.uid()
  ) returning id into v_tx_id;

  if not p_in_kind and p_split_mode is not null and p_split_mode <> 'none' then
    if p_split_mode = 'even' and p_split_breakdown is not null then
      v_n := jsonb_array_length(p_split_breakdown);
      v_per := round(p_amount / nullif(v_n, 0), 4);
      for v_member in select * from jsonb_array_elements(p_split_breakdown)
      loop
        if (v_member->>'membership_id')::uuid <> p_paid_by_membership_id then
          insert into public.group_obligations (
            group_id, owed_by_membership_id, owed_to_membership_id, owed_to_kind,
            source_transaction_id, source_resource_id,
            obligation_kind, amount_original, amount_outstanding, unit, description
          ) values (
            p_group_id, (v_member->>'membership_id')::uuid, p_paid_by_membership_id, 'member',
            v_tx_id, p_resource_id,
            'expense_share', v_per, v_per, p_unit, p_description
          );
        end if;
      end loop;
    elsif p_split_mode = 'custom' and p_split_breakdown is not null then
      for v_member in select * from jsonb_array_elements(p_split_breakdown)
      loop
        if (v_member->>'membership_id')::uuid <> p_paid_by_membership_id then
          insert into public.group_obligations (
            group_id, owed_by_membership_id, owed_to_membership_id, owed_to_kind,
            source_transaction_id, source_resource_id,
            obligation_kind, amount_original, amount_outstanding, unit, description
          ) values (
            p_group_id, (v_member->>'membership_id')::uuid, p_paid_by_membership_id, 'member',
            v_tx_id, p_resource_id,
            'expense_share',
            (v_member->>'amount')::numeric,
            (v_member->>'amount')::numeric,
            p_unit, p_description
          );
        end if;
      end loop;
    end if;
  end if;

  perform public.record_system_event(
    p_group_id, 'money.expense_recorded', 'transaction', v_tx_id, p_description,
    jsonb_build_object('amount', p_amount, 'unit', p_unit)
  );
  return v_tx_id;
end;
$$;

create or replace function public.record_contribution(
  p_group_id        uuid,
  p_resource_id     uuid default null,
  p_amount          numeric default null,
  p_unit            text default 'MXN',
  p_from_membership_id uuid default null,
  p_description     text default null,
  p_in_kind         boolean default false,
  p_client_id       text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_tx uuid;
begin
  perform public.assert_permission(p_group_id, 'contribution.record');
  if p_amount is null or p_amount <= 0 then raise exception 'amount required'; end if;
  if p_client_id is not null then
    select id into v_tx from public.group_resource_transactions
     where group_id = p_group_id and client_id = p_client_id;
    if v_tx is not null then return v_tx; end if;
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, from_membership_id,
    amount, unit, source_resource_id, source_entity_kind,
    in_kind, description, client_id, recorded_by
  ) values (
    p_group_id, p_resource_id, 'contribution', p_from_membership_id,
    p_amount, p_unit, p_resource_id, 'contribution',
    p_in_kind, p_description, p_client_id, auth.uid()
  ) returning id into v_tx;

  perform public.record_system_event(
    p_group_id, 'money.contribution_recorded', 'transaction', v_tx, p_description,
    jsonb_build_object('amount', p_amount, 'unit', p_unit, 'in_kind', p_in_kind)
  );
  return v_tx;
end;
$$;

create or replace function public.record_non_monetary_contribution(
  p_group_id         uuid,
  p_membership_id    uuid,
  p_contribution_type text,
  p_title            text,
  p_description      text default null,
  p_source_resource_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'contribution.record');
  insert into public.group_contributions (
    group_id, membership_id, contribution_type, title, description, source_resource_id, status
  ) values (
    p_group_id, p_membership_id, p_contribution_type, p_title, p_description, p_source_resource_id, 'claimed'
  ) returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'contribution.recorded', 'contribution', v_id, p_title,
    jsonb_build_object('type', p_contribution_type)
  );
  return v_id;
end;
$$;

create or replace function public.verify_contribution(
  p_contribution_id uuid,
  p_outcome         text,
  p_note            text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_c public.group_contributions%rowtype;
begin
  if p_outcome not in ('verified','rejected') then raise exception 'invalid outcome'; end if;
  select * into v_c from public.group_contributions where id = p_contribution_id for update;
  if v_c.id is null then raise exception 'contribution not found'; end if;
  perform public.assert_permission(v_c.group_id, 'records.read');

  update public.group_contributions
     set status = p_outcome, verified_by = auth.uid(),
         metadata = metadata || jsonb_build_object('verifier_note', p_note)
   where id = p_contribution_id;

  if p_outcome = 'verified' then
    insert into public.group_reputation_events (
      group_id, subject_membership_id, actor_membership_id,
      reputation_type, reason, evidence_entity_kind, evidence_entity_id
    ) values (
      v_c.group_id, v_c.membership_id,
      (select id from public.group_memberships where group_id = v_c.group_id and user_id = auth.uid()),
      'contribution_recognized', p_note, 'contribution', p_contribution_id
    );
  end if;

  perform public.record_system_event(
    v_c.group_id, 'contribution.' || p_outcome, 'contribution', p_contribution_id, p_note, '{}'::jsonb
  );
end;
$$;

create or replace function public.record_settlement(
  p_group_id            uuid,
  p_paid_by_membership_id uuid,
  p_paid_to_membership_id uuid,
  p_paid_to_kind        text,
  p_amount              numeric,
  p_unit                text,
  p_notes               text default null,
  p_client_id           text default null
)
returns table (settlement_id uuid, transaction_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settlement uuid;
  v_tx_id      uuid;
  v_remaining  numeric := p_amount;
  v_close      numeric;
  v_o          public.group_obligations%rowtype;
  v_actor_m    uuid;
begin
  perform public.assert_permission(p_group_id, 'settlement.record');
  if p_paid_to_kind not in ('member','pool','vendor','group') then raise exception 'invalid paid_to_kind'; end if;
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  if p_client_id is not null then
    select id into v_settlement from public.group_settlements
     where group_id = p_group_id and client_id = p_client_id;
    if v_settlement is not null then
      select ledger_entry_id into v_tx_id from public.group_settlements where id = v_settlement;
      return query select v_settlement, v_tx_id;
      return;
    end if;
  end if;

  insert into public.group_settlements (
    group_id, paid_by_membership_id, paid_to_membership_id, paid_to_kind,
    amount, unit, status, client_id, notes, recorded_by, confirmed_at
  ) values (
    p_group_id, p_paid_by_membership_id, p_paid_to_membership_id, p_paid_to_kind,
    p_amount, p_unit, 'confirmed', p_client_id, p_notes, auth.uid(), now()
  ) returning id into v_settlement;

  v_actor_m := (select id from public.group_memberships where group_id = p_group_id and user_id = auth.uid());

  for v_o in
    select * from public.group_obligations
     where group_id = p_group_id
       and owed_by_membership_id = p_paid_by_membership_id
       and ((p_paid_to_kind = 'member' and owed_to_membership_id = p_paid_to_membership_id)
            or (p_paid_to_kind <> 'member' and owed_to_kind = p_paid_to_kind))
       and unit = p_unit
       and status in ('open','partially_settled')
     order by created_at asc
     for update
  loop
    exit when v_remaining <= 0;
    v_close := least(v_remaining, v_o.amount_outstanding);

    insert into public.group_settlement_obligations (settlement_id, obligation_id, amount_closed)
    values (v_settlement, v_o.id, v_close);

    update public.group_obligations
       set amount_outstanding = amount_outstanding - v_close,
           status = case
             when (amount_outstanding - v_close) <= 0 then 'settled'
             else 'partially_settled'
           end
     where id = v_o.id;

    if v_close = v_o.amount_outstanding then
      insert into public.group_reputation_events (
        group_id, subject_membership_id, actor_membership_id,
        reputation_type, reason, evidence_entity_kind, evidence_entity_id
      ) values (
        p_group_id, p_paid_by_membership_id, v_actor_m,
        'commitment_kept', 'Obligación cerrada', 'obligation', v_o.id
      );
    end if;

    v_remaining := v_remaining - v_close;
  end loop;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type,
    from_membership_id, to_membership_id, paid_by_membership_id,
    amount, unit, source_entity_kind, source_entity_id,
    description, recorded_by
  )
  select p_group_id,
         (select coalesce(min(o.source_resource_id), null)
            from public.group_settlement_obligations so
            join public.group_obligations o on o.id = so.obligation_id
            where so.settlement_id = v_settlement),
         'settlement_payment',
         p_paid_by_membership_id,
         case when p_paid_to_kind = 'member' then p_paid_to_membership_id else null end,
         p_paid_by_membership_id,
         p_amount, p_unit, 'settlement', v_settlement,
         p_notes, auth.uid()
  returning id into v_tx_id;

  update public.group_settlements
     set ledger_entry_id = v_tx_id,
         metadata = case when v_remaining > 0
                         then metadata || jsonb_build_object('unallocated', v_remaining)
                         else metadata end
   where id = v_settlement;

  perform public.record_system_event(
    p_group_id, 'money.settlement_recorded', 'settlement', v_settlement, p_notes,
    jsonb_build_object('amount', p_amount, 'unit', p_unit, 'unallocated', v_remaining)
  );

  return query select v_settlement, v_tx_id;
end;
$$;

create or replace function public.record_pool_charge(
  p_group_id            uuid,
  p_target_membership_id uuid,
  p_amount              numeric,
  p_unit                text,
  p_charge_kind         text,
  p_reason              text default null,
  p_client_id           text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'pool_charge.record');
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_charge_kind not in ('quota','buy_in','fee') then raise exception 'invalid charge_kind'; end if;

  insert into public.group_obligations (
    group_id, owed_by_membership_id, owed_to_kind,
    obligation_kind, amount_original, amount_outstanding, unit,
    description, metadata
  ) values (
    p_group_id, p_target_membership_id, 'pool',
    'pool_charge', p_amount, p_amount, p_unit,
    p_reason, jsonb_build_object('charge_kind', p_charge_kind, 'client_id', p_client_id)
  ) returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'money.pool_charge_created', 'obligation', v_id, p_reason,
    jsonb_build_object('amount', p_amount, 'unit', p_unit, 'kind', p_charge_kind, 'target', p_target_membership_id)
  );
  return v_id;
end;
$$;

create or replace function public.record_payout(
  p_group_id          uuid,
  p_to_membership_id  uuid,
  p_amount            numeric,
  p_unit              text,
  p_source_resource_id uuid default null,
  p_reason            text default null,
  p_client_id         text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_tx uuid;
begin
  perform public.assert_permission(p_group_id, 'payout.record');
  if p_amount <= 0 then raise exception 'amount must be positive'; end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type, to_membership_id,
    amount, unit, source_resource_id, description, client_id, recorded_by
  ) values (
    p_group_id, p_source_resource_id, 'payout', p_to_membership_id,
    p_amount, p_unit, p_source_resource_id, p_reason, p_client_id, auth.uid()
  ) returning id into v_tx;

  perform public.record_system_event(
    p_group_id, 'money.payout_recorded', 'transaction', v_tx, p_reason,
    jsonb_build_object('amount', p_amount, 'unit', p_unit, 'to', p_to_membership_id)
  );
  return v_tx;
end;
$$;

create or replace function public.reverse_transaction(
  p_transaction_id uuid,
  p_reason         text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_tx public.group_resource_transactions%rowtype; v_new uuid;
begin
  select * into v_tx from public.group_resource_transactions where id = p_transaction_id;
  if v_tx.id is null then raise exception 'transaction not found'; end if;
  if v_tx.recorded_by <> auth.uid() and not public.has_group_permission(v_tx.group_id, 'records.read') then
    raise exception 'caller cannot reverse this transaction';
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type,
    from_membership_id, to_membership_id, paid_by_membership_id,
    amount, unit, source_entity_kind, source_entity_id,
    reversed_entry_id, description, recorded_by
  ) values (
    v_tx.group_id, v_tx.resource_id, 'reversal',
    v_tx.to_membership_id, v_tx.from_membership_id, v_tx.paid_by_membership_id,
    v_tx.amount, v_tx.unit, 'manual', null,
    p_transaction_id, p_reason, auth.uid()
  ) returning id into v_new;

  perform public.record_system_event(
    v_tx.group_id, 'money.transaction_reversed', 'transaction', p_transaction_id, p_reason,
    jsonb_build_object('reversal_id', v_new)
  );
  return v_new;
end;
$$;

create or replace function public.record_asset_valuation(
  p_resource_id uuid,
  p_value       numeric,
  p_unit        text,
  p_basis       text default 'member_estimate'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid; v_id uuid;
begin
  select group_id into v_group from public.group_resources where id = p_resource_id;
  if v_group is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_group, 'resources.update');

  insert into public.group_resource_asset_valuations (resource_id, value, unit, basis, recorded_by)
  values (p_resource_id, p_value, p_unit, p_basis, auth.uid())
  returning id into v_id;

  update public.group_resource_assets
     set current_value = p_value, current_value_unit = p_unit
   where resource_id = p_resource_id;

  perform public.record_system_event(
    v_group, 'asset.valuation_recorded', 'resource', p_resource_id, p_basis,
    jsonb_build_object('value', p_value, 'unit', p_unit)
  );
  return v_id;
end;
$$;

-- ============================================================================
-- §10. Sanctions
-- ============================================================================

create or replace function public.issue_sanction(
  p_group_id             uuid,
  p_target_membership_id uuid,
  p_sanction_kind        text,
  p_reason               text,
  p_amount               numeric default null,
  p_unit                 text default null,
  p_ends_at              timestamptz default null,
  p_rule_version_id      uuid default null,
  p_source_event_id      uuid default null,
  p_client_id            text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_obligation uuid; v_actor uuid;
begin
  perform public.assert_permission(p_group_id, 'sanctions.create');
  if p_client_id is not null then
    select id into v_id from public.group_sanctions
     where group_id = p_group_id and client_id = p_client_id;
    if v_id is not null then return v_id; end if;
  end if;

  v_actor := (select id from public.group_memberships where group_id = p_group_id and user_id = auth.uid());

  insert into public.group_sanctions (
    group_id, target_membership_id, issued_by_membership_id, rule_version_id,
    source_event_id, sanction_kind, status, amount, unit, reason, ends_at, client_id
  ) values (
    p_group_id, p_target_membership_id, v_actor, p_rule_version_id,
    p_source_event_id, p_sanction_kind, 'active', p_amount, p_unit, p_reason, p_ends_at, p_client_id
  ) returning id into v_id;

  if p_sanction_kind = 'monetary' then
    if p_amount is null or p_amount <= 0 or p_unit is null then
      raise exception 'monetary sanction requires positive amount + unit';
    end if;
    insert into public.group_obligations (
      group_id, owed_by_membership_id, owed_to_kind,
      obligation_kind, amount_original, amount_outstanding, unit, description, metadata
    ) values (
      p_group_id, p_target_membership_id, 'pool',
      'fine', p_amount, p_amount, p_unit, p_reason,
      jsonb_build_object('sanction_id', v_id)
    ) returning id into v_obligation;
    update public.group_sanctions set obligation_id = v_obligation where id = v_id;
  elsif p_sanction_kind = 'suspension' then
    perform public.set_membership_state(p_target_membership_id, 'suspended', p_reason, p_ends_at);
  end if;

  insert into public.group_reputation_events (
    group_id, subject_membership_id, actor_membership_id,
    reputation_type, reason, evidence_entity_kind, evidence_entity_id
  ) values (
    p_group_id, p_target_membership_id, v_actor,
    case when p_rule_version_id is not null then 'rule_violation' else 'commitment_broken' end,
    p_reason, 'sanction', v_id
  );

  perform public.record_system_event(
    p_group_id, 'sanction.issued', 'sanction', v_id, p_reason,
    jsonb_build_object('kind', p_sanction_kind, 'target', p_target_membership_id)
  );
  return v_id;
end;
$$;

create or replace function public.update_sanction_status(
  p_sanction_id uuid,
  p_new_status  text,
  p_reason      text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_s public.group_sanctions%rowtype;
begin
  select * into v_s from public.group_sanctions where id = p_sanction_id for update;
  if v_s.id is null then raise exception 'sanction not found'; end if;
  if p_new_status not in ('reversed','completed','cancelled') then raise exception 'invalid status'; end if;
  perform public.assert_permission(v_s.group_id, 'sanctions.update');

  update public.group_sanctions
     set status = p_new_status, resolved_at = now(),
         metadata = metadata || jsonb_build_object('resolution_reason', p_reason)
   where id = p_sanction_id;

  if p_new_status = 'reversed' and v_s.obligation_id is not null then
    update public.group_obligations
       set status = 'voided', amount_outstanding = 0,
           metadata = metadata || jsonb_build_object('voided_reason', 'sanction_reversed')
     where id = v_s.obligation_id;
  end if;

  perform public.record_system_event(
    v_s.group_id, 'sanction.' || p_new_status, 'sanction', p_sanction_id, p_reason, '{}'::jsonb
  );
end;
$$;

create or replace function public.dispute_sanction(
  p_sanction_id uuid,
  p_summary     text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_s public.group_sanctions%rowtype; v_target_user uuid; v_id uuid;
begin
  select * into v_s from public.group_sanctions where id = p_sanction_id;
  if v_s.id is null then raise exception 'sanction not found'; end if;
  select user_id into v_target_user from public.group_memberships where id = v_s.target_membership_id;
  if v_target_user <> auth.uid() and not public.has_group_permission(v_s.group_id, 'sanctions.dispute') then
    raise exception 'caller cannot dispute this sanction';
  end if;

  v_id := public.open_dispute(v_s.group_id, 'sanction', p_sanction_id,
                              'Disputa de sanción', p_summary, null);
  update public.group_sanctions set dispute_id = v_id, status = 'disputed' where id = p_sanction_id;
  return v_id;
end;
$$;

-- ============================================================================
-- §11. Disputes
-- ============================================================================

create or replace function public.open_dispute(
  p_group_id              uuid,
  p_subject_kind          text,
  p_subject_id            uuid,
  p_title                 text,
  p_description           text default null,
  p_respondent_membership_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_opener uuid;
begin
  perform public.assert_permission(p_group_id, 'disputes.open');
  v_opener := public.assert_member_of_group(p_group_id);

  insert into public.group_disputes (
    group_id, opened_by_membership_id, respondent_membership_id,
    subject_kind, subject_id, title, description, status
  ) values (
    p_group_id, v_opener, p_respondent_membership_id,
    p_subject_kind, p_subject_id, p_title, p_description, 'open'
  ) returning id into v_id;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body)
  values (v_id, v_opener, 'comment', p_description);

  perform public.record_system_event(
    p_group_id, 'dispute.opened', 'dispute', v_id, p_title,
    jsonb_build_object('subject_kind', p_subject_kind, 'subject_id', p_subject_id)
  );
  return v_id;
end;
$$;

create or replace function public.assign_mediator(
  p_dispute_id            uuid,
  p_mediator_membership_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_disputes where id = p_dispute_id for update;
  if v_group is null then raise exception 'dispute not found'; end if;
  perform public.assert_permission(v_group, 'disputes.mediate');

  update public.group_disputes
     set mediator_membership_id = p_mediator_membership_id, status = 'mediation'
   where id = p_dispute_id;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body)
  values (p_dispute_id, p_mediator_membership_id, 'status_change', 'Mediador asignado');

  perform public.record_system_event(
    v_group, 'dispute.mediator_assigned', 'dispute', p_dispute_id, null,
    jsonb_build_object('mediator', p_mediator_membership_id)
  );
end;
$$;

create or replace function public.append_dispute_event(
  p_dispute_id uuid,
  p_event_type text,
  p_body       text,
  p_metadata   jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_disputes%rowtype; v_actor uuid; v_id uuid;
begin
  select * into v_d from public.group_disputes where id = p_dispute_id;
  if v_d.id is null then raise exception 'dispute not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_d.group_id and user_id = auth.uid() and status = 'active');
  if v_actor is null then raise exception 'caller is not a member'; end if;

  if v_actor not in (v_d.opened_by_membership_id, v_d.respondent_membership_id, v_d.mediator_membership_id)
     and not public.has_group_permission(v_d.group_id, 'disputes.mediate') then
    raise exception 'caller cannot append to this dispute';
  end if;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body, metadata)
  values (p_dispute_id, v_actor, p_event_type, p_body, coalesce(p_metadata, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.record_dispute_resolution(
  p_dispute_id      uuid,
  p_method          text,
  p_resolution_text text,
  p_outcome         jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_disputes%rowtype; v_actor uuid;
begin
  select * into v_d from public.group_disputes where id = p_dispute_id for update;
  if v_d.id is null then raise exception 'dispute not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_d.group_id and user_id = auth.uid());
  if v_d.mediator_membership_id <> v_actor and not public.has_group_permission(v_d.group_id, 'disputes.resolve') then
    raise exception 'caller cannot resolve this dispute';
  end if;

  update public.group_disputes
     set status = 'resolved', resolution_method = p_method, resolution = p_resolution_text, resolved_at = now()
   where id = p_dispute_id;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body, metadata)
  values (p_dispute_id, v_actor, 'resolution', p_resolution_text, coalesce(p_outcome, '{}'::jsonb));

  if v_d.subject_kind = 'sanction' and p_outcome ? 'reverse_sanction' then
    perform public.update_sanction_status(v_d.subject_id, 'reversed', 'dispute_resolution');
  end if;

  insert into public.group_reputation_events (group_id, subject_membership_id, actor_membership_id, reputation_type, reason, evidence_entity_kind, evidence_entity_id)
  select v_d.group_id, m, v_actor, 'conflict_resolved', p_resolution_text, 'dispute', p_dispute_id
  from unnest(ARRAY[v_d.opened_by_membership_id, v_d.respondent_membership_id]) as m
  where m is not null;

  perform public.record_system_event(
    v_d.group_id, 'dispute.resolved', 'dispute', p_dispute_id, p_resolution_text,
    coalesce(p_outcome, '{}'::jsonb)
  );
end;
$$;

create or replace function public.escalate_dispute_to_vote(
  p_dispute_id        uuid,
  p_decision_title    text,
  p_decision_method   text,
  p_closes_at         timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_disputes%rowtype; v_decision uuid; v_actor uuid;
begin
  select * into v_d from public.group_disputes where id = p_dispute_id for update;
  if v_d.id is null then raise exception 'dispute not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_d.group_id and user_id = auth.uid());
  if v_d.mediator_membership_id <> v_actor then
    raise exception 'only the assigned mediator can escalate';
  end if;

  v_decision := public.start_vote(
    v_d.group_id, p_decision_title, v_d.description,
    'sanction_appeal', p_decision_method, 'majority',
    null, p_closes_at, null, null, false,
    'dispute', p_dispute_id, null
  );

  update public.group_disputes
     set status = 'escalated', escalated_decision_id = v_decision
   where id = p_dispute_id;

  perform public.record_system_event(
    v_d.group_id, 'dispute.escalated', 'dispute', p_dispute_id, null,
    jsonb_build_object('decision_id', v_decision)
  );
  return v_decision;
end;
$$;

-- ============================================================================
-- §12. Decisions
-- ============================================================================

create or replace function public.start_vote(
  p_group_id          uuid,
  p_title             text,
  p_body              text,
  p_decision_type     text,
  p_method            text,
  p_legitimacy_source text default 'majority',
  p_opens_at          timestamptz default null,
  p_closes_at         timestamptz default null,
  p_threshold_pct     numeric default null,
  p_quorum_pct        numeric default null,
  p_committee_only    boolean default false,
  p_reference_kind    text default null,
  p_reference_id      uuid default null,
  p_options           jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_opt jsonb; v_sort int := 0;
begin
  perform public.assert_permission(p_group_id, 'decisions.create');

  insert into public.group_decisions (
    group_id, title, body, decision_type, method, legitimacy_source,
    status, threshold_pct, quorum_pct, committee_only,
    reference_kind, reference_id, opens_at, closes_at, created_by
  ) values (
    p_group_id, p_title, p_body, p_decision_type, p_method, p_legitimacy_source,
    'open', p_threshold_pct, p_quorum_pct, p_committee_only,
    p_reference_kind, p_reference_id,
    coalesce(p_opens_at, now()), p_closes_at, auth.uid()
  ) returning id into v_id;

  if p_options is not null then
    for v_opt in select * from jsonb_array_elements(p_options)
    loop
      insert into public.group_decision_options (decision_id, label, body, sort_order)
      values (v_id, v_opt->>'label', v_opt->>'body', v_sort);
      v_sort := v_sort + 1;
    end loop;
  end if;

  perform public.record_system_event(
    p_group_id, 'decision.started', 'decision', v_id, p_title,
    jsonb_build_object('method', p_method, 'closes_at', p_closes_at)
  );
  return v_id;
end;
$$;

create or replace function public.cast_vote(
  p_decision_id uuid,
  p_option_id   uuid default null,
  p_vote_value  text default null,
  p_weight      numeric default 1,
  p_reason      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_decisions%rowtype; v_voter uuid; v_id uuid;
begin
  select * into v_d from public.group_decisions where id = p_decision_id;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then raise exception 'decision is not open'; end if;
  if v_d.closes_at is not null and v_d.closes_at < now() then raise exception 'voting window closed'; end if;
  perform public.assert_permission(v_d.group_id, 'decisions.vote');
  v_voter := public.assert_member_of_group(v_d.group_id);

  insert into public.group_votes (
    group_id, decision_id, voter_membership_id, option_id, vote_value, weight, reason
  ) values (
    v_d.group_id, p_decision_id, v_voter, p_option_id, p_vote_value, coalesce(p_weight, 1), p_reason
  ) returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.cancel_vote(
  p_decision_id uuid,
  p_reason      text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_decisions%rowtype;
begin
  select * into v_d from public.group_decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found'; end if;
  perform public.assert_permission(v_d.group_id, 'decisions.resolve');

  update public.group_decisions
     set status = 'cancelled', decided_at = now(),
         result = result || jsonb_build_object('cancel_reason', p_reason)
   where id = p_decision_id;

  perform public.record_system_event(
    v_d.group_id, 'decision.cancelled', 'decision', p_decision_id, p_reason, '{}'::jsonb
  );
end;
$$;

create or replace function public.finalize_vote(p_decision_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_d       public.group_decisions%rowtype;
  v_yes     numeric := 0;
  v_no      numeric := 0;
  v_abstain numeric := 0;
  v_block   numeric := 0;
  v_total   numeric;
  v_outcome text;
  v_quorum_total numeric;
  v_threshold numeric;
begin
  select * into v_d from public.group_decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then return v_d.status; end if;

  with current as (
    select distinct on (voter_membership_id) *
    from public.group_votes
    where decision_id = p_decision_id
    order by voter_membership_id, seq desc
  )
  select
    coalesce(sum(weight) filter (where vote_value = 'yes'), 0),
    coalesce(sum(weight) filter (where vote_value = 'no'), 0),
    coalesce(sum(weight) filter (where vote_value = 'abstain'), 0),
    coalesce(sum(weight) filter (where vote_value = 'block'), 0)
  into v_yes, v_no, v_abstain, v_block from current;

  v_total := v_yes + v_no + v_abstain + v_block;

  if v_d.quorum_pct is not null then
    select count(*) into v_quorum_total
    from public.group_memberships
    where group_id = v_d.group_id and status = 'active';
    if v_quorum_total = 0 or (v_total * 100.0 / v_quorum_total) < v_d.quorum_pct then
      v_outcome := 'no_quorum';
    end if;
  end if;

  v_threshold := coalesce(v_d.threshold_pct,
                          case v_d.method
                            when 'consensus'    then 100
                            when 'supermajority' then 66.66
                            when 'consent'      then 100
                            else 50.01
                          end);

  if v_outcome is null then
    if v_d.method = 'consent' and v_block > 0 then
      v_outcome := 'rejected';
    elsif (v_yes + v_no) > 0 and (v_yes * 100.0 / (v_yes + v_no)) >= v_threshold then
      v_outcome := 'passed';
    else
      v_outcome := 'rejected';
    end if;
  end if;

  update public.group_decisions
     set status = case when v_outcome = 'passed' then 'passed' else 'rejected' end,
         decided_at = now(),
         result = jsonb_build_object('yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block, 'outcome', v_outcome)
   where id = p_decision_id;

  if v_outcome = 'passed' then
    if v_d.reference_kind = 'sanction' and v_d.reference_id is not null then
      perform public.update_sanction_status(v_d.reference_id, 'reversed', 'vote_pass');
    elsif v_d.reference_kind = 'dispute' and v_d.reference_id is not null then
      update public.group_disputes set status = 'resolved', resolved_at = now() where id = v_d.reference_id;
    elsif v_d.reference_kind = 'mandate_grant' and v_d.reference_id is not null then
      update public.group_mandates set source_decision_id = p_decision_id where id = v_d.reference_id;
    elsif v_d.reference_kind = 'mandate_revoke' and v_d.reference_id is not null then
      perform public.revoke_mandate(v_d.reference_id, 'vote_pass');
    elsif v_d.reference_kind = 'dissolution' and v_d.reference_id is not null then
      perform public.approve_dissolution(v_d.reference_id);
    end if;
  end if;

  perform public.record_system_event(
    v_d.group_id, 'decision.finalized', 'decision', p_decision_id, v_outcome,
    jsonb_build_object('yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block)
  );

  return v_outcome;
end;
$$;

create or replace function public.current_vote_for(
  p_decision_id        uuid,
  p_voter_membership_id uuid
)
returns public.group_votes
language sql
stable
security definer
set search_path = public
as $$
  select * from public.group_votes
   where decision_id = p_decision_id and voter_membership_id = p_voter_membership_id
   order by seq desc limit 1;
$$;

-- ============================================================================
-- §13. Reputation
-- ============================================================================

create or replace function public.record_reputation_event(
  p_group_id            uuid,
  p_subject_membership_id uuid,
  p_reputation_type     text,
  p_reason              text default null,
  p_evidence_entity_kind text default null,
  p_evidence_entity_id  uuid default null,
  p_visibility          text default 'members'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_actor uuid;
begin
  perform public.assert_permission(p_group_id, 'reputation.record');
  v_actor := (select id from public.group_memberships where group_id = p_group_id and user_id = auth.uid());
  insert into public.group_reputation_events (
    group_id, subject_membership_id, actor_membership_id,
    reputation_type, reason, evidence_entity_kind, evidence_entity_id, visibility
  ) values (
    p_group_id, p_subject_membership_id, v_actor,
    p_reputation_type, p_reason, p_evidence_entity_kind, p_evidence_entity_id, p_visibility
  ) returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.retract_reputation_event(
  p_event_id uuid,
  p_reason   text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_e public.group_reputation_events%rowtype; v_actor uuid;
begin
  select * into v_e from public.group_reputation_events where id = p_event_id;
  if v_e.id is null then raise exception 'reputation event not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_e.group_id and user_id = auth.uid());
  if v_e.actor_membership_id <> v_actor and not public.has_group_permission(v_e.group_id, 'reputation.record') then
    raise exception 'caller cannot retract this event';
  end if;
  update public.group_reputation_events
     set status = 'retracted',
         metadata = metadata || jsonb_build_object('retraction_reason', p_reason)
   where id = p_event_id;
end;
$$;

-- ============================================================================
-- §14. Culture
-- ============================================================================

create or replace function public.propose_norm(
  p_group_id  uuid,
  p_norm_type text,
  p_title     text,
  p_body      text default null,
  p_visibility text default 'members'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'culture.propose');
  insert into public.group_cultural_norms (
    group_id, norm_type, title, body, visibility, status, proposed_by
  ) values (
    p_group_id, p_norm_type, p_title, p_body, p_visibility, 'proposed', auth.uid()
  ) returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'norm.proposed', 'norm', v_id, p_title,
    jsonb_build_object('norm_type', p_norm_type)
  );
  return v_id;
end;
$$;

create or replace function public.endorse_norm(p_norm_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_n public.group_cultural_norms%rowtype; v_threshold int;
begin
  select * into v_n from public.group_cultural_norms where id = p_norm_id for update;
  if v_n.id is null then raise exception 'norm not found'; end if;
  perform public.assert_permission(v_n.group_id, 'culture.endorse');

  update public.group_cultural_norms
     set endorsed_count = endorsed_count + 1
   where id = p_norm_id;

  select coalesce(((settings->>'norm_endorse_threshold')::int), 3) into v_threshold
    from public.groups where id = v_n.group_id;

  if v_n.endorsed_count + 1 >= v_threshold and v_n.status = 'proposed' then
    update public.group_cultural_norms set status = 'endorsed' where id = p_norm_id;
    perform public.record_system_event(
      v_n.group_id, 'norm.endorsed', 'norm', p_norm_id, v_n.title, '{}'::jsonb
    );
  end if;
end;
$$;

create or replace function public.retire_norm(p_norm_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_n public.group_cultural_norms%rowtype;
begin
  select * into v_n from public.group_cultural_norms where id = p_norm_id for update;
  if v_n.id is null then raise exception 'norm not found'; end if;
  if v_n.proposed_by <> auth.uid() and not public.has_group_permission(v_n.group_id, 'culture.endorse') then
    raise exception 'caller cannot retire this norm';
  end if;
  update public.group_cultural_norms
     set status = 'retired',
         metadata = metadata || jsonb_build_object('retire_reason', p_reason)
   where id = p_norm_id;
  perform public.record_system_event(
    v_n.group_id, 'norm.retired', 'norm', p_norm_id, p_reason, '{}'::jsonb
  );
end;
$$;

-- ============================================================================
-- §15. Dissolution
-- ============================================================================

create or replace function public.propose_dissolution(
  p_group_id          uuid,
  p_reason            text,
  p_plan              jsonb default '{}'::jsonb,
  p_asset_disposition jsonb default '{}'::jsonb,
  p_obligations_plan  jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_decision uuid;
begin
  perform public.assert_permission(p_group_id, 'group.dissolve');
  insert into public.group_dissolutions (
    group_id, initiated_by, status, reason, plan, asset_disposition, obligations_plan
  ) values (
    p_group_id, auth.uid(), 'proposed', p_reason,
    coalesce(p_plan, '{}'::jsonb), coalesce(p_asset_disposition, '{}'::jsonb),
    coalesce(p_obligations_plan, '{}'::jsonb)
  ) returning id into v_id;

  v_decision := public.start_vote(
    p_group_id, 'Disolución del grupo', p_reason,
    'dissolution', 'supermajority', 'supermajority',
    null, now() + interval '14 days', 66.66, 50,
    false, 'dissolution', v_id, null
  );

  update public.group_dissolutions set source_decision_id = v_decision where id = v_id;
  update public.groups set status = 'dissolving' where id = p_group_id;

  perform public.record_system_event(
    p_group_id, 'dissolution.proposed', 'dissolution', v_id, p_reason,
    jsonb_build_object('decision_id', v_decision)
  );
  return v_id;
end;
$$;

create or replace function public.approve_dissolution(p_dissolution_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_dissolutions%rowtype;
begin
  select * into v_d from public.group_dissolutions where id = p_dissolution_id for update;
  if v_d.id is null then raise exception 'dissolution not found'; end if;
  update public.group_dissolutions
     set status = 'approved', approved_at = now()
   where id = p_dissolution_id;

  perform public.record_system_event(
    v_d.group_id, 'dissolution.approved', 'dissolution', p_dissolution_id, null, '{}'::jsonb
  );
end;
$$;

create or replace function public.record_liquidation_step(
  p_dissolution_id uuid,
  p_step_kind      text,
  p_payload        jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_dissolutions%rowtype;
begin
  select * into v_d from public.group_dissolutions where id = p_dissolution_id for update;
  if v_d.id is null then raise exception 'dissolution not found'; end if;
  perform public.assert_permission(v_d.group_id, 'group.dissolve');

  update public.group_dissolutions
     set plan = jsonb_set(
                  coalesce(plan, '{}'::jsonb),
                  '{steps}',
                  coalesce(plan->'steps', '[]'::jsonb) ||
                    jsonb_build_array(jsonb_build_object(
                      'kind', p_step_kind, 'at', now(), 'payload', coalesce(p_payload, '{}'::jsonb)
                    )),
                  true
                )
   where id = p_dissolution_id;

  perform public.record_system_event(
    v_d.group_id, 'dissolution.step', 'dissolution', p_dissolution_id, p_step_kind, coalesce(p_payload, '{}'::jsonb)
  );
end;
$$;

create or replace function public.finalize_dissolution(p_dissolution_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_dissolutions%rowtype; v_open int;
begin
  select * into v_d from public.group_dissolutions where id = p_dissolution_id for update;
  if v_d.id is null then raise exception 'dissolution not found'; end if;
  perform public.assert_permission(v_d.group_id, 'group.dissolve');

  select count(*) into v_open from public.group_obligations
   where group_id = v_d.group_id and status in ('open','partially_settled');
  if v_open > 0 then raise exception 'cannot finalize: % obligations still open', v_open; end if;

  update public.group_dissolutions
     set status = 'executed', executed_at = now()
   where id = p_dissolution_id;

  update public.groups
     set status = 'dissolved', dissolved_at = now()
   where id = v_d.group_id;

  update public.group_memberships
     set status = 'left', left_at = now(), left_reason = 'dissolution'
   where group_id = v_d.group_id and status = 'active';

  perform public.record_system_event(
    v_d.group_id, 'dissolution.finalized', 'dissolution', p_dissolution_id, null, '{}'::jsonb
  );
end;
$$;

-- ============================================================================
-- §16. Memory & read helpers
-- ============================================================================

create or replace function public.member_balance_in_group(
  p_group_id      uuid,
  p_membership_id uuid
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select sum(case
                  when transaction_type in ('contribution','income','refund','reversal') then amount
                  when transaction_type in ('expense','payout') and from_membership_id = p_membership_id then -amount
                  else 0
                end)
       from public.group_resource_transactions
       where group_id = p_group_id
         and (from_membership_id = p_membership_id or to_membership_id = p_membership_id or paid_by_membership_id = p_membership_id)
    ), 0
  )
  - coalesce(
    (select sum(amount_outstanding)
       from public.group_obligations
       where group_id = p_group_id and owed_by_membership_id = p_membership_id
         and status in ('open','partially_settled')
    ), 0
  );
$$;

create or replace function public.member_obligation_summary(
  p_group_id      uuid,
  p_membership_id uuid
)
returns table (
  obligation_id      uuid,
  kind               text,
  amount_outstanding numeric,
  owed_to_kind       text,
  owed_to_label      text
)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.obligation_kind, o.amount_outstanding, o.owed_to_kind,
         coalesce(p.display_name, p.username, o.owed_to_kind)
  from public.group_obligations o
  left join public.group_memberships m on m.id = o.owed_to_membership_id
  left join public.profiles p on p.id = m.user_id
  where o.group_id = p_group_id
    and o.owed_by_membership_id = p_membership_id
    and o.status in ('open','partially_settled')
  order by o.created_at;
$$;

create or replace function public.current_votes_for_decision(p_decision_id uuid)
returns setof public.group_votes
language sql
stable
security definer
set search_path = public
as $$
  select distinct on (voter_membership_id) *
  from public.group_votes
  where decision_id = p_decision_id
  order by voter_membership_id, seq desc;
$$;

create or replace function public.group_summary(p_group_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'group_id', p_group_id,
    'member_count', (select count(*) from public.group_memberships where group_id = p_group_id and status = 'active'),
    'open_decisions', (select count(*) from public.group_decisions where group_id = p_group_id and status = 'open'),
    'open_disputes', (select count(*) from public.group_disputes where group_id = p_group_id and status in ('open','in_review','mediation')),
    'open_obligations', (select count(*) from public.group_obligations where group_id = p_group_id and status in ('open','partially_settled')),
    'recent_events', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'event_type', e.event_type, 'summary', e.summary, 'occurred_at', e.occurred_at) order by e.id desc), '[]'::jsonb)
      from (
        select id, event_type, summary, occurred_at
        from public.group_events
        where group_id = p_group_id
        order by id desc
        limit 20
      ) e
    )
  );
$$;

-- ============================================================================
-- §17. Auth wrappers (stubs — Supabase Auth handles OTP server-side)
-- ============================================================================

create or replace function public.delete_and_export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_export jsonb;
begin
  if v_uid is null then raise exception 'must be authenticated'; end if;

  v_export := jsonb_build_object(
    'profile', (select to_jsonb(p) from public.profiles p where p.id = v_uid),
    'memberships', (select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) from public.group_memberships m where m.user_id = v_uid),
    'contributions', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from public.group_contributions c join public.group_memberships m on m.id = c.membership_id where m.user_id = v_uid),
    'votes', (select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) from public.group_votes v join public.group_memberships m on m.id = v.voter_membership_id where m.user_id = v_uid),
    'exported_at', now()
  );

  update public.group_mandates
     set status = 'revoked', revoked_at = now(), revoked_reason = 'user_deleted'
   where representative_membership_id in (select id from public.group_memberships where user_id = v_uid)
     and status = 'active';

  update public.group_memberships
     set status = 'left', left_at = now(), left_reason = 'user_deleted'
   where user_id = v_uid and status = 'active';

  update public.profiles
     set deleted_at = now(), display_name = null, avatar_url = null, bio = null
   where id = v_uid;

  return v_export;
end;
$$;

-- ============================================================================
-- §18. Lockdown — revoke EXECUTE on internal helpers from anon
-- ============================================================================

revoke execute on function public.record_system_event(uuid, text, text, uuid, text, jsonb) from anon, public;
revoke execute on function public.evaluate_rules_for_event(uuid)                              from anon, public;
revoke execute on function public.approve_dissolution(uuid)                                   from anon, public;

-- All other RPCs remain callable by authenticated; RLS + assert_permission gates enforce per-call security.

-- ============================================================================
-- End — CanonicalRPCs.sql
-- ============================================================================
