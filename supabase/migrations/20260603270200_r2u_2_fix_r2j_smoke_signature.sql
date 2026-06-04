-- ============================================================================
-- R.2U.2 — FIX: _smoke_r2j_list_activity_rpc usa firma 3-arg de list_activity
-- ============================================================================
-- R.2U.2 reemplazó la firma 3-arg `list_activity(uuid, int, timestamptz)` por
-- la 4-arg que incluye `p_include_descendants boolean`. El smoke R.2J usaba
-- `has_function_privilege('anon', 'public.list_activity(uuid, int, timestamptz)', 'EXECUTE')`
-- que ahora falla porque la firma vieja no existe.
--
-- Esta mig recrea el smoke con la firma nueva. El resto de la lógica queda igual.
-- ============================================================================

create or replace function public._smoke_r2j_list_activity_rpc()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_world jsonb;
  v_cena uuid; v_viaje uuid;
  v_page1 jsonb; v_page2 jsonb;
  v_oldest timestamptz;
  v_caught boolean;
begin
  v_world := public._r2j_make_world();
  v_cena := (v_world->>'cena')::uuid;
  v_viaje := (v_world->>'viaje')::uuid;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', (v_world->>'u_jose'))::text, true);
  v_page1 := public.list_activity(v_cena);
  if jsonb_array_length(v_page1->'activity') < 10 then
    raise exception 'R2J LIST FAIL: miembro no puede listar activity (% rows)', jsonb_array_length(v_page1->'activity');
  end if;

  v_page1 := public.list_activity(v_cena, 5);
  if jsonb_array_length(v_page1->'activity') <> 5 then
    raise exception 'R2J LIST FAIL: limit 5 no aplicado (% rows)', jsonb_array_length(v_page1->'activity');
  end if;

  v_page1 := public.list_activity(v_cena, 5000);
  if (v_page1->>'limit')::integer <> 100 or jsonb_array_length(v_page1->'activity') > 100 then
    raise exception 'R2J LIST FAIL: el cap de 100 no se aplicó';
  end if;

  v_page1 := public.list_activity(v_cena, 10);
  select min((e->>'occurred_at')::timestamptz) into v_oldest
    from jsonb_array_elements(v_page1->'activity') e;
  v_page2 := public.list_activity(v_cena, 10, v_oldest);
  if jsonb_array_length(v_page2->'activity') = 0 then
    raise exception 'R2J LIST FAIL: la página 2 está vacía';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_page2->'activity') e
    where (e->>'occurred_at')::timestamptz >= v_oldest
  ) then
    raise exception 'R2J LIST FAIL: la página 2 contiene rows posteriores al corte';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_page1->'activity') e1
    join jsonb_array_elements(v_page2->'activity') e2 on e1->>'id' = e2->>'id'
  ) then
    raise exception 'R2J LIST FAIL: overlap entre páginas';
  end if;

  v_page1 := public.list_activity(v_cena, 100);
  if exists (
    select 1 from jsonb_array_elements(v_page1->'activity') e
    where (e->>'id')::uuid in (select id from public.activity_events where context_actor_id = v_viaje)
  ) then
    raise exception 'R2J LIST FAIL: el listado de la cena mezcla activity del viaje';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', (v_world->>'u_abuelo'))::text, true);
  v_caught := false;
  begin
    perform public.list_activity(v_cena);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2J LIST FAIL: no-miembro pudo listar activity'; end if;

  -- Firma actualizada R.2U.2: 4 args con include_descendants
  if has_function_privilege('anon', 'public.list_activity(uuid, int, timestamptz, boolean)', 'EXECUTE') then
    raise exception 'R2J LIST FAIL: anon puede ejecutar list_activity';
  end if;

  perform public._r2j_cleanup_world(v_world);
  raise notice 'R.2J LIST ACTIVITY RPC: PASS (limit, cap 100, paginación, aislamiento, permisos)';
end; $$;

revoke all on function public._smoke_r2j_list_activity_rpc() from public, anon, authenticated;
