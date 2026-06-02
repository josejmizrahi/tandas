-- ============================================================================
-- R.2A — AUTHORITY LAYER: DoD smoke dedicado
-- ============================================================================
-- Los 4 RPCs de R.2A ya existen (M.1/M.2/M.3 + R.2-1):
--   1. has_actor_authority(context, member, permission)   → M.2
--   2. current_actor_id()                                  → M.1
--   3. context_candidates()                                → M.3
--   4. context_summary(context) con counts                 → M.3 + R.2-1
--
-- Este smoke prueba el DoD de R.2A punto por punto, en un solo lugar:
--   ✓ Un usuario puede ver sus contextos
--   ✓ Un miembro activo puede ver un contexto
--   ✓ Un no-miembro no puede verlo
--   ✓ Un rol con permiso permite acción
--   ✓ Un rol sin permiso bloquea acción
--   ✓ anon no puede leer ni ejecutar RPCs sensibles
-- ============================================================================

create or replace function public._smoke_mvp2_r2a_authority_dod()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_admin uuid; a_admin uuid;   -- founder/admin del contexto
  u_member uuid; a_member uuid; -- miembro normal
  u_outsider uuid; a_outsider uuid; -- no-miembro
  v_ctx uuid;
  v_result jsonb;
  v_caught boolean;
  v_tbl text;
  v_fn text;
begin
  -- Setup: 3 personas + 1 contexto con admin y member
  select auth_id, actor_id into u_admin, a_admin from public._r2_make_person('R2A Admin', '+5210000020');
  select auth_id, actor_id into u_member, a_member from public._r2_make_person('R2A Member', '+5210000021');
  select auth_id, actor_id into u_outsider, a_outsider from public._r2_make_person('R2A Outsider', '+5210000022');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_ctx := (public.create_context('R2A Authority Test', 'collective', 'friend_group'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_member);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- ════════════════════════════════════════════════════════════
  -- DoD 1: Un usuario puede ver sus contextos
  -- ════════════════════════════════════════════════════════════
  v_result := public.context_candidates();
  if not exists (
    select 1 from jsonb_array_elements(v_result->'contexts') c
    where (c->>'context_actor_id')::uuid = v_ctx::uuid
  ) then
    raise exception 'R2A DoD 1 FAIL: el usuario no ve su contexto en context_candidates';
  end if;
  -- y su contexto personal también
  if (v_result->'personal_context'->>'id')::uuid is distinct from a_member then
    raise exception 'R2A DoD 1 FAIL: personal_context incorrecto';
  end if;

  -- ════════════════════════════════════════════════════════════
  -- DoD 2: Un miembro activo puede ver un contexto
  -- ════════════════════════════════════════════════════════════
  v_result := public.context_summary(v_ctx::uuid);
  if (v_result->>'members_count')::integer <> 2 then
    raise exception 'R2A DoD 2 FAIL: miembro activo no puede ver context_summary';
  end if;
  -- current_actor_id() resuelve correctamente
  if public.current_actor_id() is distinct from a_member then
    raise exception 'R2A DoD 2 FAIL: current_actor_id() incorrecto';
  end if;

  -- ════════════════════════════════════════════════════════════
  -- DoD 3: Un no-miembro NO puede verlo
  -- ════════════════════════════════════════════════════════════
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_outsider::text)::text, true);
  v_caught := false;
  begin
    v_result := public.context_summary(v_ctx::uuid);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2A DoD 3 FAIL: no-miembro pudo ver context_summary'; end if;
  -- y el contexto NO aparece en sus candidates
  v_result := public.context_candidates();
  if exists (
    select 1 from jsonb_array_elements(v_result->'contexts') c
    where (c->>'context_actor_id')::uuid = v_ctx::uuid
  ) then
    raise exception 'R2A DoD 3 FAIL: contexto ajeno aparece en candidates de no-miembro';
  end if;
  -- has_actor_authority retorna false para no-miembro
  if public.has_actor_authority(v_ctx::uuid, a_outsider, 'context.view') then
    raise exception 'R2A DoD 3 FAIL: no-miembro tiene autoridad';
  end if;

  -- ════════════════════════════════════════════════════════════
  -- DoD 4: Un rol CON permiso permite acción
  -- ════════════════════════════════════════════════════════════
  -- admin tiene rules.manage → puede crear regla
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  if not public.has_actor_authority(v_ctx::uuid, a_admin, 'rules.manage') then
    raise exception 'R2A DoD 4 FAIL: has_actor_authority niega permiso que el rol admin tiene';
  end if;
  v_result := public.create_rule(v_ctx::uuid, 'R2A regla de prueba',
    p_trigger_event_type := 'event.checked_in',
    p_consequences := '[{"type": "fine", "amount": 50, "currency": "MXN"}]'::jsonb);
  if (v_result->>'rule_id') is null then
    raise exception 'R2A DoD 4 FAIL: rol con permiso no pudo ejecutar la acción';
  end if;

  -- ════════════════════════════════════════════════════════════
  -- DoD 5: Un rol SIN permiso bloquea acción
  -- ════════════════════════════════════════════════════════════
  -- member NO tiene rules.manage → create_rule bloqueado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text)::text, true);
  if public.has_actor_authority(v_ctx::uuid, a_member, 'rules.manage') then
    raise exception 'R2A DoD 5 FAIL: has_actor_authority concede permiso que el rol member no tiene';
  end if;
  v_caught := false;
  begin
    perform public.create_rule(v_ctx::uuid, 'R2A hack', p_trigger_event_type := 'x');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then raise exception 'R2A DoD 5 FAIL: rol sin permiso ejecutó la acción'; end if;
  -- pero SÍ tiene los permisos de member (events.view, decisions.vote)
  if not public.has_actor_authority(v_ctx::uuid, a_member, 'events.view') then
    raise exception 'R2A DoD 5 FAIL: member perdió sus permisos básicos';
  end if;

  -- ════════════════════════════════════════════════════════════
  -- DoD 6: anon no puede leer tablas ni ejecutar RPCs sensibles
  -- ════════════════════════════════════════════════════════════
  -- tablas: anon sin SELECT en NINGUNA tabla del schema
  for v_tbl in select tablename from pg_tables where schemaname = 'public' loop
    if has_table_privilege('anon', 'public.' || v_tbl, 'SELECT') then
      raise exception 'R2A DoD 6 FAIL: anon tiene SELECT en %', v_tbl;
    end if;
  end loop;
  -- RPCs del authority layer: anon sin EXECUTE
  foreach v_fn in array array[
    'public.has_actor_authority(uuid, uuid, text)',
    'public.current_actor_id()',
    'public.context_candidates()',
    'public.context_summary(uuid)',
    'public.create_context(text, text, text, text, jsonb)',
    'public.invite_member(uuid, uuid, text)',
    'public.accept_invitation(uuid)',
    'public.create_rule(uuid, text, text, jsonb, jsonb, text, text, int)',
    'public.record_expense(uuid, numeric, text, text, uuid[], uuid, jsonb, text)',
    'public.generate_settlement_batch(uuid, text)'
  ] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'R2A DoD 6 FAIL: anon puede ejecutar %', v_fn;
    end if;
  end loop;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid,
    array[a_admin, a_member, a_outsider],
    array[u_admin, u_member, u_outsider]);

  raise notice 'R.2A AUTHORITY LAYER DoD: 6/6 PASS';
end; $$;

revoke all on function public._smoke_mvp2_r2a_authority_dod() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2a_authority_dod() is
  'R.2A DoD: usuario ve sus contextos · miembro ve contexto · no-miembro bloqueado · rol con permiso permite · rol sin permiso bloquea · anon sin acceso.';
