create or replace function public._smoke_r5a_b1_resources_backfill()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_count int;
  v_caught boolean;
  v_auth uuid := gen_random_uuid();
  v_actor uuid;
  v_ctx uuid;
  v_res uuid;
  v_class text;
  v_subtype text;
  v_legacy_type text;
begin
  -- C1: columnas presentes con FK + nullable
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='resources'
                   and column_name='resource_class_key' and is_nullable='YES') then
    raise exception 'r5a.b1 C1a: resource_class_key missing or NOT NULL prematuro'; end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='resources'
                   and column_name='resource_subtype_key' and is_nullable='YES') then
    raise exception 'r5a.b1 C1b: resource_subtype_key missing or NOT NULL prematuro'; end if;
  if not exists (select 1 from information_schema.table_constraints
                 where constraint_name='resources_resource_class_key_fkey' and table_name='resources') then
    raise exception 'r5a.b1 C1c: FK resources_resource_class_key_fkey missing'; end if;
  if not exists (select 1 from information_schema.table_constraints
                 where constraint_name='resources_resource_subtype_key_fkey' and table_name='resources') then
    raise exception 'r5a.b1 C1d: FK resources_resource_subtype_key_fkey missing'; end if;

  -- C2: backfill 100% (cero filas con class o subtype NULL)
  select count(*) into v_count from public.resources
   where resource_class_key is null or resource_subtype_key is null;
  if v_count <> 0 then
    raise exception 'r5a.b1 C2: % rows aun con class/subtype NULL post-backfill', v_count; end if;

  -- C3: mapping function coverage — los 16 type_keys vivos del catalogo devuelven
  --     class+subtype validos (FK-ables a los catalogos).
  for v_legacy_type in select type_key from public.resource_type_catalog loop
    v_class := public._r5a_b1_class_for(v_legacy_type);
    v_subtype := public._r5a_b1_subtype_for(v_legacy_type);
    if not exists (select 1 from public.resource_classes where class_key = v_class) then
      raise exception 'r5a.b1 C3a: mapping returned invalid class % for type %', v_class, v_legacy_type; end if;
    if not exists (select 1 from public.resource_subtypes where subtype_key = v_subtype) then
      raise exception 'r5a.b1 C3b: mapping returned invalid subtype % for type %', v_subtype, v_legacy_type; end if;
  end loop;

  -- C4: founder-canon spot checks (mapping correcto)
  if public._r5a_b1_class_for('house') <> 'real_estate' or public._r5a_b1_subtype_for('house') <> 'primary_residence' then
    raise exception 'r5a.b1 C4a: house mapping wrong'; end if;
  if public._r5a_b1_class_for('cash_pool') <> 'financial' or public._r5a_b1_subtype_for('cash_pool') <> 'money_pool' then
    raise exception 'r5a.b1 C4b: cash_pool mapping wrong'; end if;
  if public._r5a_b1_class_for('trust_asset') <> 'financial' or public._r5a_b1_subtype_for('trust_asset') <> 'trust_fund' then
    raise exception 'r5a.b1 C4c: trust_asset mapping wrong'; end if;
  if public._r5a_b1_class_for('game') <> 'event' or public._r5a_b1_subtype_for('game') <> 'recurring_event' then
    raise exception 'r5a.b1 C4d: game mapping wrong'; end if;
  if public._r5a_b1_class_for('other') <> 'generic' or public._r5a_b1_subtype_for('other') <> 'generic_resource' then
    raise exception 'r5a.b1 C4e: other mapping wrong'; end if;

  -- C5: fallback para type desconocido devuelve generic / generic_resource
  if public._r5a_b1_class_for('_does_not_exist') <> 'generic' then
    raise exception 'r5a.b1 C5a: unknown type fallback class wrong'; end if;
  if public._r5a_b1_subtype_for('_does_not_exist') <> 'generic_resource' then
    raise exception 'r5a.b1 C5b: unknown type fallback subtype wrong'; end if;

  -- C6: trigger derive class/subtype en INSERT cuando NULL — via create_resource RPC
  v_actor := public._create_person_actor_for_auth_user(v_auth, '_smoke_b1 user', '+520000000961', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth::text)::text, true);
  v_ctx := (public.create_context('_smoke_b1 ctx', 'collective', 'project'))->>'context_actor_id';
  v_res := (public.create_resource(v_ctx, 'house', '_smoke_b1 casa', null, null, 'MXN', '{}'::jsonb))->>'resource_id';
  select resource_class_key, resource_subtype_key into v_class, v_subtype
    from public.resources where id = v_res;
  if v_class <> 'real_estate' then
    raise exception 'r5a.b1 C6a: trigger no derivo class para house, got %', v_class; end if;
  if v_subtype <> 'primary_residence' then
    raise exception 'r5a.b1 C6b: trigger no derivo subtype para house, got %', v_subtype; end if;

  -- C7: trigger respeta valores explicitos (no sobreescribe)
  update public.resources
     set resource_class_key = 'real_estate',
         resource_subtype_key = 'vacation_home'
   where id = v_res;
  -- Trigger NO se dispara por UPDATE de class/subtype (solo UPDATE OF resource_type)
  select resource_class_key, resource_subtype_key into v_class, v_subtype
    from public.resources where id = v_res;
  if v_class <> 'real_estate' or v_subtype <> 'vacation_home' then
    raise exception 'r5a.b1 C7: trigger sobreescribio valores explicitos (% / %)', v_class, v_subtype; end if;

  -- C8: trigger re-deriva si cambia resource_type y NULL los nuevos
  update public.resources
     set resource_class_key = null,
         resource_subtype_key = null
   where id = v_res;
  update public.resources set resource_type = 'cash_pool' where id = v_res;
  select resource_class_key, resource_subtype_key into v_class, v_subtype
    from public.resources where id = v_res;
  if v_class <> 'financial' or v_subtype <> 'money_pool' then
    raise exception 'r5a.b1 C8: trigger no re-derivo en UPDATE resource_type (% / %)', v_class, v_subtype; end if;

  -- C9: FK rechaza class_key invalido
  v_caught := false;
  begin
    update public.resources set resource_class_key = '_nonexistent_class' where id = v_res;
  exception when foreign_key_violation then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b1 C9a: FK class_key no rechazo valor invalido'; end if;

  v_caught := false;
  begin
    update public.resources set resource_subtype_key = '_nonexistent_subtype' where id = v_res;
  exception when foreign_key_violation then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b1 C9b: FK subtype_key no rechazo valor invalido'; end if;

  -- C10: RPCs vivos siguen funcionando sin cambios (no leen class/subtype)
  if jsonb_typeof((public.resource_detail(v_res))->'resource') <> 'object' then
    raise exception 'r5a.b1 C10a: resource_detail rompio post-B.1'; end if;
  if not public.resource_can(v_res, 'monetary') then
    raise exception 'r5a.b1 C10b: resource_can monetary fallo para cash_pool'; end if;

  -- cleanup best-effort
  begin
    delete from public.resources where id = v_res;
    delete from public.actor_memberships where context_actor_id = v_ctx;
    delete from public.actors where id = v_ctx;
    delete from public.actors where id = v_actor;
  exception when others then null; end;

  raise notice '_smoke_r5a_b1_resources_backfill OK (FKs + backfill 100%% + trigger derive + RPCs vivos intactos)';
end;
$$;

revoke all on function public._smoke_r5a_b1_resources_backfill() from public, anon;
grant execute on function public._smoke_r5a_b1_resources_backfill() to authenticated, service_role;
