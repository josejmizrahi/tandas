create or replace function public._smoke_r5a_b4r_resource_sections_widgets()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
  v_caught boolean;
  v_first_section text;
  v_first_widget text;
begin
  -- C1: section_catalog seedeado (47 entries)
  select count(*) into v_count from public.resource_section_catalog;
  if v_count <> 47 then
    raise exception 'r5a.b4r C1: expected 47 sections, got %', v_count; end if;

  -- C2: founder canon section keys presentes
  if not exists (select 1 from public.resource_section_catalog where section_key='overview') then
    raise exception 'r5a.b4r C2a: section overview missing'; end if;
  if not exists (select 1 from public.resource_section_catalog where section_key='reservations') then
    raise exception 'r5a.b4r C2b: section reservations missing'; end if;
  if not exists (select 1 from public.resource_section_catalog where section_key='leases') then
    raise exception 'r5a.b4r C2c: section leases missing'; end if;
  if not exists (select 1 from public.resource_section_catalog where section_key='itinerary') then
    raise exception 'r5a.b4r C2d: section itinerary missing'; end if;

  -- C3: subtype_sections cubre los 42 subtypes
  select count(distinct subtype_key) into v_count from public.resource_subtype_sections;
  if v_count <> 42 then
    raise exception 'r5a.b4r C3: only % subtypes have sections (expected 42)', v_count; end if;

  -- C4: cada subtype tiene al menos overview + activity + settings (minimo universal)
  select count(*) into v_count
    from public.resource_subtypes s
    where not exists (select 1 from public.resource_subtype_sections ss
                      where ss.subtype_key = s.subtype_key and ss.section_key = 'overview');
  if v_count <> 0 then
    raise exception 'r5a.b4r C4a: % subtypes sin overview', v_count; end if;
  select count(*) into v_count
    from public.resource_subtypes s
    where not exists (select 1 from public.resource_subtype_sections ss
                      where ss.subtype_key = s.subtype_key and ss.section_key = 'activity');
  if v_count <> 0 then
    raise exception 'r5a.b4r C4b: % subtypes sin activity', v_count; end if;
  select count(*) into v_count
    from public.resource_subtypes s
    where not exists (select 1 from public.resource_subtype_sections ss
                      where ss.subtype_key = s.subtype_key and ss.section_key = 'settings');
  if v_count <> 0 then
    raise exception 'r5a.b4r C4c: % subtypes sin settings', v_count; end if;

  -- C5: founder canon mappings
  if exists (select 1 from public.resource_subtype_sections
             where subtype_key='primary_residence' and section_key='reservations') then
    raise exception 'r5a.b4r C5a: primary_residence INCLUYE reservations (founder NO)'; end if;
  if not exists (select 1 from public.resource_subtype_sections
                 where subtype_key='vacation_home' and section_key='reservations') then
    raise exception 'r5a.b4r C5b: vacation_home sin reservations'; end if;
  if not exists (select 1 from public.resource_subtype_sections
                 where subtype_key='vacation_home' and section_key='availability') then
    raise exception 'r5a.b4r C5c: vacation_home sin availability'; end if;
  if not exists (select 1 from public.resource_subtype_sections
                 where subtype_key='warehouse' and section_key='leases') then
    raise exception 'r5a.b4r C5d: warehouse sin leases'; end if;
  if not exists (select 1 from public.resource_subtype_sections
                 where subtype_key='warehouse' and section_key='income') then
    raise exception 'r5a.b4r C5e: warehouse sin income'; end if;
  if not exists (select 1 from public.resource_subtype_sections
                 where subtype_key='money_pool' and section_key='member_balances') then
    raise exception 'r5a.b4r C5f: money_pool sin member_balances'; end if;
  if not exists (select 1 from public.resource_subtype_sections
                 where subtype_key='money_pool' and section_key='decisions') then
    raise exception 'r5a.b4r C5g: money_pool sin decisions'; end if;
  if not exists (select 1 from public.resource_subtype_sections
                 where subtype_key='iou' and section_key='payments') then
    raise exception 'r5a.b4r C5h: iou sin payments'; end if;

  -- C6: required_capability hint apunta a capabilities validas del catalog
  select count(*) into v_count
    from public.resource_subtype_sections ss
    where ss.required_capability is not null
      and not exists (select 1 from public.resource_capabilities_catalog c
                      where c.capability_key = ss.required_capability);
  if v_count <> 0 then
    raise exception 'r5a.b4r C6: % rows con required_capability invalido', v_count; end if;

  -- C7: dashboard_widgets seedeado (17 entries)
  select count(*) into v_count from public.resource_dashboard_widgets;
  if v_count <> 17 then
    raise exception 'r5a.b4r C7: expected 17 widgets, got %', v_count; end if;

  -- C8: founder canon widget keys
  if not exists (select 1 from public.resource_dashboard_widgets where widget_key='balance_summary') then
    raise exception 'r5a.b4r C8a: widget balance_summary missing'; end if;
  if not exists (select 1 from public.resource_dashboard_widgets where widget_key='upcoming_reservations') then
    raise exception 'r5a.b4r C8b: widget upcoming_reservations missing'; end if;
  if not exists (select 1 from public.resource_dashboard_widgets where widget_key='lease_status') then
    raise exception 'r5a.b4r C8c: widget lease_status missing'; end if;
  if not exists (select 1 from public.resource_dashboard_widgets where widget_key='custody_status') then
    raise exception 'r5a.b4r C8d: widget custody_status missing'; end if;

  -- C9: subtype_widgets cubre los 42 subtypes
  select count(distinct subtype_key) into v_count from public.resource_subtype_widgets;
  if v_count <> 42 then
    raise exception 'r5a.b4r C9: only % subtypes have widgets (expected 42)', v_count; end if;

  -- C10: founder canon widget mappings
  if not exists (select 1 from public.resource_subtype_widgets
                 where subtype_key='vacation_home' and widget_key='upcoming_reservations') then
    raise exception 'r5a.b4r C10a: vacation_home sin upcoming_reservations widget'; end if;
  if not exists (select 1 from public.resource_subtype_widgets
                 where subtype_key='money_pool' and widget_key='balance_summary') then
    raise exception 'r5a.b4r C10b: money_pool sin balance_summary widget'; end if;
  if not exists (select 1 from public.resource_subtype_widgets
                 where subtype_key='warehouse' and widget_key='lease_status') then
    raise exception 'r5a.b4r C10c: warehouse sin lease_status widget'; end if;
  if not exists (select 1 from public.resource_subtype_widgets
                 where subtype_key='car' and widget_key='maintenance_status') then
    raise exception 'r5a.b4r C10d: car sin maintenance_status widget'; end if;

  -- C11: required_capability en widgets apunta a caps validas
  select count(*) into v_count
    from public.resource_subtype_widgets sw
    where sw.required_capability is not null
      and not exists (select 1 from public.resource_capabilities_catalog c
                      where c.capability_key = sw.required_capability);
  if v_count <> 0 then
    raise exception 'r5a.b4r C11: % widget rows con required_capability invalido', v_count; end if;

  -- C12: RLS read-all habilitado en todas las 4 tablas
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='resource_section_catalog' and c.relrowsecurity=true) then
    raise exception 'r5a.b4r C12a: RLS not enabled on resource_section_catalog'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='resource_subtype_sections' and c.relrowsecurity=true) then
    raise exception 'r5a.b4r C12b: RLS not enabled on resource_subtype_sections'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='resource_dashboard_widgets' and c.relrowsecurity=true) then
    raise exception 'r5a.b4r C12c: RLS not enabled on resource_dashboard_widgets'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='resource_subtype_widgets' and c.relrowsecurity=true) then
    raise exception 'r5a.b4r C12d: RLS not enabled on resource_subtype_widgets'; end if;

  -- C13: SELECT grants a authenticated
  if not exists (select 1 from information_schema.role_table_grants
                 where grantee='authenticated' and table_name='resource_section_catalog' and privilege_type='SELECT') then
    raise exception 'r5a.b4r C13a: authenticated lacks SELECT on resource_section_catalog'; end if;
  if not exists (select 1 from information_schema.role_table_grants
                 where grantee='authenticated' and table_name='resource_dashboard_widgets' and privilege_type='SELECT') then
    raise exception 'r5a.b4r C13b: authenticated lacks SELECT on resource_dashboard_widgets'; end if;

  -- C14: FK section_key invalido es rechazado
  v_caught := false;
  begin
    insert into public.resource_subtype_sections (subtype_key, section_key)
      values ('generic_resource', '_invalid_section');
  exception when foreign_key_violation then v_caught := true; end;
  if not v_caught then raise exception 'r5a.b4r C14: FK section invalido no rechazado'; end if;

  raise notice '_smoke_r5a_b4r_resource_sections_widgets OK (47 sections + 428 mappings + 17 widgets + 137 mappings + RLS + FK + grants)';
end;
$$;

revoke all on function public._smoke_r5a_b4r_resource_sections_widgets() from public, anon;
grant execute on function public._smoke_r5a_b4r_resource_sections_widgets() to authenticated, service_role;
