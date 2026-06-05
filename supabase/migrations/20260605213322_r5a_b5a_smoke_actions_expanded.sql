create or replace function public._smoke_r5a_b5a_actions_expanded()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
  v_caught boolean;
  v_invalid_caps int;
begin
  -- C1: cols nuevas existen
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='resource_action_catalog'
                   and column_name='execution_mode') then
    raise exception 'r5a.b5a C1a: col execution_mode missing'; end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='resource_action_catalog'
                   and column_name='decision_template_key') then
    raise exception 'r5a.b5a C1b: col decision_template_key missing'; end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='resource_action_catalog'
                   and column_name='dangerous') then
    raise exception 'r5a.b5a C1c: col dangerous missing'; end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='resource_action_catalog'
                   and column_name='confirmation_required') then
    raise exception 'r5a.b5a C1d: col confirmation_required missing'; end if;

  -- C2: total acciones >= 90 (20 viejas + 70 nuevas)
  select count(*) into v_count from public.resource_action_catalog;
  if v_count < 90 then
    raise exception 'r5a.b5a C2: expected >=90 actions, got %', v_count; end if;

  -- C3: founder canon acciones nuevas presentes
  if not exists (select 1 from public.resource_action_catalog where action_key='archive_resource') then
    raise exception 'r5a.b5a C3a: archive_resource missing'; end if;
  if not exists (select 1 from public.resource_action_catalog where action_key='transfer_ownership') then
    raise exception 'r5a.b5a C3b: transfer_ownership missing'; end if;
  if not exists (select 1 from public.resource_action_catalog where action_key='create_lease') then
    raise exception 'r5a.b5a C3c: create_lease missing'; end if;
  if not exists (select 1 from public.resource_action_catalog where action_key='accept_obligation') then
    raise exception 'r5a.b5a C3d: accept_obligation missing'; end if;
  if not exists (select 1 from public.resource_action_catalog where action_key='record_payment') then
    raise exception 'r5a.b5a C3e: record_payment missing'; end if;

  -- C4: transfer_ownership marcado request_decision con template 'resource_transfer' + dangerous + confirm
  select count(*) into v_count from public.resource_action_catalog
   where action_key='transfer_ownership'
     and execution_mode='request_decision'
     and decision_template_key='resource_transfer'
     and dangerous = true
     and confirmation_required = true;
  if v_count <> 1 then
    raise exception 'r5a.b5a C4: transfer_ownership metadata wrong'; end if;

  -- C5: request_transfer marcado request_decision pero NO dangerous (es solicitar, no ejecutar)
  select count(*) into v_count from public.resource_action_catalog
   where action_key='request_transfer'
     and execution_mode='request_decision'
     and decision_template_key='resource_transfer'
     and dangerous = false;
  if v_count <> 1 then
    raise exception 'r5a.b5a C5: request_transfer metadata wrong'; end if;

  -- C6: required_capability hints apuntan a caps validas
  select count(*) into v_invalid_caps
    from public.resource_action_catalog rac
    where rac.required_capability is not null
      and not exists (select 1 from public.resource_capabilities_catalog c
                      where c.capability_key = rac.required_capability);
  if v_invalid_caps <> 0 then
    raise exception 'r5a.b5a C6: % actions con required_capability invalido', v_invalid_caps; end if;

  -- C7: CHECK constraint en execution_mode rechaza values invalidos
  v_caught := false;
  begin
    insert into public.resource_action_catalog (action_key, display_name, ui_section, execution_mode)
      values ('_smoke_invalid_mode', 'invalid', 'settings', 'foo');
  exception when check_violation then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b5a C7: CHECK execution_mode no rechazo valor invalido'; end if;

  -- C8: acciones EXISTENTES (pre-B.5a) tienen execution_mode='execute' por default
  select count(*) into v_count from public.resource_action_catalog
   where action_key in ('record_expense','grant_right','reserve_resource','attach_document')
     and execution_mode='execute';
  if v_count <> 4 then
    raise exception 'r5a.b5a C8: acciones legacy con execution_mode mal, got %', v_count; end if;

  -- C9: dangerous + confirmation_required en acciones obvias
  if not exists (select 1 from public.resource_action_catalog
                 where action_key='archive_resource' and dangerous and confirmation_required) then
    raise exception 'r5a.b5a C9a: archive_resource no dangerous/confirm'; end if;
  if not exists (select 1 from public.resource_action_catalog
                 where action_key='cancel_event' and dangerous and confirmation_required) then
    raise exception 'r5a.b5a C9b: cancel_event no dangerous/confirm'; end if;
  if not exists (select 1 from public.resource_action_catalog
                 where action_key='terminate_lease' and dangerous and confirmation_required) then
    raise exception 'r5a.b5a C9c: terminate_lease no dangerous/confirm'; end if;
  if not exists (select 1 from public.resource_action_catalog
                 where action_key='forgive_obligation' and dangerous and confirmation_required) then
    raise exception 'r5a.b5a C9d: forgive_obligation no dangerous/confirm'; end if;

  -- C10: required_rights non-empty para acciones nuevas
  select count(*) into v_count
    from public.resource_action_catalog
    where action_key in ('archive_resource','create_lease','record_payment','cancel_event','transfer_ownership')
      and array_length(required_rights, 1) > 0;
  if v_count <> 5 then
    raise exception 'r5a.b5a C10: acciones nuevas con required_rights vacio, got %', v_count; end if;

  -- C11: catalog query intacto
  if jsonb_typeof(to_jsonb((
       select coalesce(jsonb_agg(action_key), '[]'::jsonb)
       from public.resource_action_catalog limit 5))) <> 'array' then
    raise exception 'r5a.b5a C11: catalog query rompio'; end if;

  raise notice '_smoke_r5a_b5a_actions_expanded OK (90 actions + execution_mode + dangerous + confirm + 2 request_decision + founder canon)';
end;
$$;

revoke all on function public._smoke_r5a_b5a_actions_expanded() from public, anon;
grant execute on function public._smoke_r5a_b5a_actions_expanded() to authenticated, service_role;
