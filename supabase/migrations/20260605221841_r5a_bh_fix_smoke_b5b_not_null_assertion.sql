-- ============================================================================
-- R.5A.B.H fix: smoke B.5b -- el contrato cambio por hardening item 5.
-- C6 ahora asserta NOT NULL DEFAULT false (no nullable).
-- ============================================================================
create or replace function public._smoke_r5a_b5b_action_forms()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
  v_caught boolean;
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='resource_action_forms') then
    raise exception 'r5a.b5b C1a: resource_action_forms missing'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='resource_action_forms' and c.relrowsecurity=true) then
    raise exception 'r5a.b5b C1b: RLS not enabled'; end if;

  select count(*) into v_count
    from public.resource_action_catalog rac
    where not exists (select 1 from public.resource_action_forms raf where raf.action_key = rac.action_key);
  if v_count <> 0 then
    raise exception 'r5a.b5b C2: % actions sin form', v_count; end if;

  select count(*) into v_count from public.resource_action_forms;
  if v_count < 90 then
    raise exception 'r5a.b5b C3: expected >=90 forms, got %', v_count; end if;

  if not (select form_schema->'fields' @> '[{"key":"starts_at"}]'::jsonb
             and form_schema->'fields' @> '[{"key":"ends_at"}]'::jsonb
          from public.resource_action_forms where action_key='reserve_resource') then
    raise exception 'r5a.b5b C4a: reserve_resource form schema wrong'; end if;
  if not (select form_schema->'fields' @> '[{"key":"amount"}]'::jsonb
             and form_schema->'fields' @> '[{"key":"split_method"}]'::jsonb
          from public.resource_action_forms where action_key='record_expense') then
    raise exception 'r5a.b5b C4b: record_expense form schema wrong'; end if;
  if not (select form_schema->'fields' @> '[{"key":"new_owner_actor_id"}]'::jsonb
          from public.resource_action_forms where action_key='transfer_ownership') then
    raise exception 'r5a.b5b C4c: transfer_ownership form schema wrong'; end if;
  if not (select form_schema->'fields' @> '[{"key":"lessee_actor_id"}]'::jsonb
             and form_schema->'fields' @> '[{"key":"monthly_rent"}]'::jsonb
          from public.resource_action_forms where action_key='create_lease') then
    raise exception 'r5a.b5b C4d: create_lease form schema wrong'; end if;

  if (select default_payload->>'currency' from public.resource_action_forms where action_key='record_expense') <> 'MXN' then
    raise exception 'r5a.b5b C5a: record_expense default currency wrong'; end if;
  if (select default_payload->>'split_method' from public.resource_action_forms where action_key='record_expense') <> 'equal' then
    raise exception 'r5a.b5b C5b: record_expense default split_method wrong'; end if;

  -- C6 (R.5A.B.H): NOT NULL DEFAULT false (founder review item 5)
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='resource_action_forms'
                   and column_name='confirmation_required' and is_nullable='NO'
                   and column_default = 'false') then
    raise exception 'r5a.b5b C6a: confirmation_required no es NOT NULL DEFAULT false (hardening)'; end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='resource_action_forms'
                   and column_name='dangerous' and is_nullable='NO'
                   and column_default = 'false') then
    raise exception 'r5a.b5b C6b: dangerous no es NOT NULL DEFAULT false (hardening)'; end if;

  insert into public.resource_action_catalog (action_key, display_name, ui_section) values ('_smoke_b5b_temp', 'temp', 'settings');
  insert into public.resource_action_forms (action_key) values ('_smoke_b5b_temp');
  if not exists (select 1 from public.resource_action_forms where action_key='_smoke_b5b_temp') then
    raise exception 'r5a.b5b C7a: setup form temp fallo'; end if;
  delete from public.resource_action_catalog where action_key='_smoke_b5b_temp';
  if exists (select 1 from public.resource_action_forms where action_key='_smoke_b5b_temp') then
    raise exception 'r5a.b5b C7b: cascade delete fallo'; end if;

  v_caught := false;
  begin
    insert into public.resource_action_forms (action_key) values ('_smoke_invalid_action');
  exception when foreign_key_violation then v_caught := true; end;
  if not v_caught then raise exception 'r5a.b5b C8: FK action_key invalido no rechazado'; end if;

  if not exists (select 1 from information_schema.role_table_grants
                 where grantee='authenticated' and table_name='resource_action_forms' and privilege_type='SELECT') then
    raise exception 'r5a.b5b C9: authenticated lacks SELECT'; end if;
  if exists (select 1 from information_schema.role_table_grants
             where grantee='authenticated' and table_name='resource_action_forms'
               and privilege_type in ('INSERT','UPDATE','DELETE')) then
    raise exception 'r5a.b5b C10: authenticated tiene writes'; end if;

  raise notice '_smoke_r5a_b5b_action_forms OK (post-B.H: 90/90 forms + cascade + FK + RLS + NOT NULL DEFAULT false en dangerous/confirmation_required)';
end;
$$;

revoke all on function public._smoke_r5a_b5b_action_forms() from public, anon;
grant execute on function public._smoke_r5a_b5b_action_forms() to authenticated, service_role;
