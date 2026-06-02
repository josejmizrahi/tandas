-- §2. Purpose
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
    p_group_id, 'purpose.set', 'purpose', v_id, 'Propósito actualizado',
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

-- §3. Roles & Permissions
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

-- §4. Mandates
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
    p_group_id, 'mandate.granted', 'mandate', v_id, 'Mandato otorgado',
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

-- §5. Rules
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
    v_rule.group_id, 'rule.published', 'rule', p_rule_id, 'Versión de regla publicada',
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
