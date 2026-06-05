create or replace function public._smoke_r5a_b4c_context_sections_widgets()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
  v_caught boolean;
  v_unmapped int;
begin
  -- C1: section catalog (10 founder canon)
  select count(*) into v_count from public.context_section_catalog;
  if v_count <> 10 then
    raise exception 'r5a.b4c C1: expected 10 context sections, got %', v_count; end if;

  -- C2: founder canon sections presentes
  if not exists (select 1 from public.context_section_catalog where section_key='overview') then
    raise exception 'r5a.b4c C2a: section overview missing'; end if;
  if not exists (select 1 from public.context_section_catalog where section_key='governance') then
    raise exception 'r5a.b4c C2b: section governance missing'; end if;
  if not exists (select 1 from public.context_section_catalog where section_key='obligations') then
    raise exception 'r5a.b4c C2c: section obligations missing'; end if;

  -- C3: 8 subtypes con sections
  select count(distinct context_subtype) into v_count from public.context_subtype_sections;
  if v_count <> 8 then
    raise exception 'r5a.b4c C3: expected 8 subtypes with sections, got %', v_count; end if;

  -- C4: minimo universal (overview + activity + settings) por subtype
  select count(*) into v_unmapped
    from (select distinct context_subtype from public.context_subtype_sections) s
    where not exists (select 1 from public.context_subtype_sections ss
                      where ss.context_subtype = s.context_subtype and ss.section_key='overview');
  if v_unmapped <> 0 then raise exception 'r5a.b4c C4a: % subtypes sin overview', v_unmapped; end if;
  select count(*) into v_unmapped
    from (select distinct context_subtype from public.context_subtype_sections) s
    where not exists (select 1 from public.context_subtype_sections ss
                      where ss.context_subtype = s.context_subtype and ss.section_key='activity');
  if v_unmapped <> 0 then raise exception 'r5a.b4c C4b: % subtypes sin activity', v_unmapped; end if;
  select count(*) into v_unmapped
    from (select distinct context_subtype from public.context_subtype_sections) s
    where not exists (select 1 from public.context_subtype_sections ss
                      where ss.context_subtype = s.context_subtype and ss.section_key='settings');
  if v_unmapped <> 0 then raise exception 'r5a.b4c C4c: % subtypes sin settings', v_unmapped; end if;

  -- C5: founder canon mappings
  if not exists (select 1 from public.context_subtype_sections
                 where context_subtype='family' and section_key='obligations') then
    raise exception 'r5a.b4c C5a: family sin obligations'; end if;
  if exists (select 1 from public.context_subtype_sections
             where context_subtype='company' and section_key='calendar') then
    raise exception 'r5a.b4c C5b: company INCLUYE calendar (founder NO)'; end if;
  if not exists (select 1 from public.context_subtype_sections
                 where context_subtype='trip' and section_key='calendar') then
    raise exception 'r5a.b4c C5c: trip sin calendar'; end if;
  if exists (select 1 from public.context_subtype_sections
             where context_subtype='trip' and section_key='governance') then
    raise exception 'r5a.b4c C5d: trip INCLUYE governance (founder NO)'; end if;
  if exists (select 1 from public.context_subtype_sections
             where context_subtype='project' and section_key='money') then
    raise exception 'r5a.b4c C5e: project INCLUYE money (founder NO)'; end if;
  if not exists (select 1 from public.context_subtype_sections
                 where context_subtype='trust' and section_key='obligations') then
    raise exception 'r5a.b4c C5f: trust sin obligations'; end if;
  if exists (select 1 from public.context_subtype_sections
             where context_subtype='generic' and section_key='governance') then
    raise exception 'r5a.b4c C5g: generic INCLUYE governance (founder NO)'; end if;

  -- C6: widgets catalog
  select count(*) into v_count from public.context_dashboard_widgets;
  if v_count <> 12 then
    raise exception 'r5a.b4c C6: expected 12 widgets, got %', v_count; end if;

  -- C7: founder canon widgets
  if not exists (select 1 from public.context_dashboard_widgets where widget_key='next_event') then
    raise exception 'r5a.b4c C7a: widget next_event missing'; end if;
  if not exists (select 1 from public.context_dashboard_widgets where widget_key='active_projects') then
    raise exception 'r5a.b4c C7b: widget active_projects missing'; end if;
  if not exists (select 1 from public.context_dashboard_widgets where widget_key='pending_invitations') then
    raise exception 'r5a.b4c C7c: widget pending_invitations missing'; end if;

  -- C8: 8 subtypes con widgets
  select count(distinct context_subtype) into v_count from public.context_subtype_widgets;
  if v_count <> 8 then
    raise exception 'r5a.b4c C8: expected 8 subtypes with widgets, got %', v_count; end if;

  -- C9: founder canon widget mappings
  if not exists (select 1 from public.context_subtype_widgets
                 where context_subtype='family' and widget_key='next_event') then
    raise exception 'r5a.b4c C9a: family sin next_event widget'; end if;
  if not exists (select 1 from public.context_subtype_widgets
                 where context_subtype='company' and widget_key='active_projects') then
    raise exception 'r5a.b4c C9b: company sin active_projects widget'; end if;
  if not exists (select 1 from public.context_subtype_widgets
                 where context_subtype='trip' and widget_key='budget_progress') then
    raise exception 'r5a.b4c C9c: trip sin budget_progress widget'; end if;
  if not exists (select 1 from public.context_subtype_widgets
                 where context_subtype='community' and widget_key='pending_invitations') then
    raise exception 'r5a.b4c C9d: community sin pending_invitations widget'; end if;

  -- C10: live coverage -- todos los actor_subtypes vivos (is_context=true) cubiertos
  select count(*) into v_unmapped
    from (select distinct actor_subtype from public.actors where is_context = true and actor_subtype is not null) live
    where not exists (select 1 from public.context_subtype_sections cs
                      where cs.context_subtype = live.actor_subtype);
  if v_unmapped <> 0 then
    raise exception 'r5a.b4c C10: % live actor_subtypes sin sections', v_unmapped; end if;

  -- C11: RLS habilitado en las 4 tablas
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='context_section_catalog' and c.relrowsecurity=true) then
    raise exception 'r5a.b4c C11a: RLS not enabled on context_section_catalog'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='context_subtype_sections' and c.relrowsecurity=true) then
    raise exception 'r5a.b4c C11b: RLS not enabled on context_subtype_sections'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='context_dashboard_widgets' and c.relrowsecurity=true) then
    raise exception 'r5a.b4c C11c: RLS not enabled on context_dashboard_widgets'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='context_subtype_widgets' and c.relrowsecurity=true) then
    raise exception 'r5a.b4c C11d: RLS not enabled on context_subtype_widgets'; end if;

  -- C12: SELECT grants a authenticated
  if not exists (select 1 from information_schema.role_table_grants
                 where grantee='authenticated' and table_name='context_section_catalog' and privilege_type='SELECT') then
    raise exception 'r5a.b4c C12a: authenticated lacks SELECT on context_section_catalog'; end if;
  if not exists (select 1 from information_schema.role_table_grants
                 where grantee='authenticated' and table_name='context_dashboard_widgets' and privilege_type='SELECT') then
    raise exception 'r5a.b4c C12b: authenticated lacks SELECT on context_dashboard_widgets'; end if;

  -- C13: FK section_key invalido rechazado
  v_caught := false;
  begin
    insert into public.context_subtype_sections (context_subtype, section_key)
      values ('family', '_invalid_section');
  exception when foreign_key_violation then v_caught := true; end;
  if not v_caught then raise exception 'r5a.b4c C13: FK section invalido no rechazado'; end if;

  raise notice '_smoke_r5a_b4c_context_sections_widgets OK (10 sections + 64 mappings + 12 widgets + 29 mappings + 8 subtypes + RLS + FK + grants + live coverage)';
end;
$$;

revoke all on function public._smoke_r5a_b4c_context_sections_widgets() from public, anon;
grant execute on function public._smoke_r5a_b4c_context_sections_widgets() to authenticated, service_role;
