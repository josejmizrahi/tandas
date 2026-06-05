create or replace function public._smoke_r5a_b0_class_subtype_catalogs()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
  v_caught boolean;
begin
  -- C1: tablas creadas
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='resource_classes') then
    raise exception 'r5a.b0 C1a: resource_classes missing'; end if;
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='resource_subtypes') then
    raise exception 'r5a.b0 C1b: resource_subtypes missing'; end if;

  -- C2: RLS enabled
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='resource_classes' and c.relrowsecurity=true) then
    raise exception 'r5a.b0 C2a: RLS not enabled on resource_classes'; end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='resource_subtypes' and c.relrowsecurity=true) then
    raise exception 'r5a.b0 C2b: RLS not enabled on resource_subtypes'; end if;

  -- C3: 17 clases seedeadas
  select count(*) into v_count from public.resource_classes;
  if v_count <> 17 then
    raise exception 'r5a.b0 C3: expected 17 classes, got %', v_count; end if;

  -- C4: 42 subtipos seedeados
  select count(*) into v_count from public.resource_subtypes;
  if v_count <> 42 then
    raise exception 'r5a.b0 C4: expected 42 subtypes, got %', v_count; end if;

  -- C5: founder-locked class keys presentes
  if not exists (select 1 from public.resource_classes where class_key='real_estate') then
    raise exception 'r5a.b0 C5a: class real_estate missing'; end if;
  if not exists (select 1 from public.resource_classes where class_key='financial') then
    raise exception 'r5a.b0 C5b: class financial missing'; end if;
  if not exists (select 1 from public.resource_classes where class_key='event') then
    raise exception 'r5a.b0 C5c: class event missing'; end if;
  if not exists (select 1 from public.resource_classes where class_key='obligation') then
    raise exception 'r5a.b0 C5d: class obligation missing'; end if;
  if not exists (select 1 from public.resource_classes where class_key='generic') then
    raise exception 'r5a.b0 C5e: class generic (fallback) missing'; end if;

  -- C6: subtipos founder-canon presentes y bien mapeados
  if not exists (select 1 from public.resource_subtypes
                 where subtype_key='primary_residence' and class_key='real_estate') then
    raise exception 'r5a.b0 C6a: subtype primary_residence missing or wrong class'; end if;
  if not exists (select 1 from public.resource_subtypes
                 where subtype_key='vacation_home' and class_key='real_estate') then
    raise exception 'r5a.b0 C6b: subtype vacation_home missing or wrong class'; end if;
  if not exists (select 1 from public.resource_subtypes
                 where subtype_key='warehouse' and class_key='real_estate') then
    raise exception 'r5a.b0 C6c: subtype warehouse missing or wrong class'; end if;
  if not exists (select 1 from public.resource_subtypes
                 where subtype_key='money_pool' and class_key='financial') then
    raise exception 'r5a.b0 C6d: subtype money_pool missing or wrong class'; end if;
  if not exists (select 1 from public.resource_subtypes
                 where subtype_key='recurring_event' and class_key='event') then
    raise exception 'r5a.b0 C6e: subtype recurring_event missing or wrong class'; end if;
  if not exists (select 1 from public.resource_subtypes
                 where subtype_key='iou' and class_key='obligation') then
    raise exception 'r5a.b0 C6f: subtype iou missing or wrong class'; end if;
  if not exists (select 1 from public.resource_subtypes
                 where subtype_key='contract' and class_key='document') then
    raise exception 'r5a.b0 C6g: subtype contract missing or wrong class'; end if;
  if not exists (select 1 from public.resource_subtypes
                 where subtype_key='generic_resource' and class_key='generic') then
    raise exception 'r5a.b0 C6h: subtype generic_resource (fallback) missing'; end if;

  -- C7: integridad FK -- todos los subtypes tienen class valida
  select count(*) into v_count
    from public.resource_subtypes s
    left join public.resource_classes c on c.class_key = s.class_key
    where c.class_key is null;
  if v_count <> 0 then
    raise exception 'r5a.b0 C7: % subtypes orphan (FK broken)', v_count; end if;

  -- C8: FK rechaza subtype con class invalida
  v_caught := false;
  begin
    insert into public.resource_subtypes (subtype_key, class_key, display_name)
      values ('_smoke_invalid_subtype', '_smoke_nonexistent_class', 'invalid');
  exception when foreign_key_violation then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b0 C8: FK did not reject orphan subtype'; end if;

  -- C9: PK rechaza duplicate class_key
  v_caught := false;
  begin
    insert into public.resource_classes (class_key, display_name) values ('real_estate', 'duplicate');
  exception when unique_violation then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b0 C9: PK did not reject duplicate class_key'; end if;

  -- C10: idempotencia de seeds (ON CONFLICT DO NOTHING) - re-insert no rompe
  insert into public.resource_classes (class_key, display_name) values ('real_estate', 'Inmuebles')
    on conflict (class_key) do nothing;
  select count(*) into v_count from public.resource_classes;
  if v_count <> 17 then
    raise exception 'r5a.b0 C10: idempotency broken, classes count drifted to %', v_count; end if;

  -- C11: grant SELECT a authenticated (catalogo es global)
  if not exists (select 1 from information_schema.role_table_grants
                 where grantee='authenticated' and table_name='resource_classes' and privilege_type='SELECT') then
    raise exception 'r5a.b0 C11a: authenticated lacks SELECT on resource_classes'; end if;
  if not exists (select 1 from information_schema.role_table_grants
                 where grantee='authenticated' and table_name='resource_subtypes' and privilege_type='SELECT') then
    raise exception 'r5a.b0 C11b: authenticated lacks SELECT on resource_subtypes'; end if;

  raise notice '_smoke_r5a_b0_class_subtype_catalogs OK (17 classes + 42 subtypes + RLS + FK + grants)';
end;
$$;

revoke all on function public._smoke_r5a_b0_class_subtype_catalogs() from public, anon;
grant execute on function public._smoke_r5a_b0_class_subtype_catalogs() to authenticated, service_role;
