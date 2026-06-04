-- ============================================================================
-- R.3A.6 — SMOKES (6)
-- ============================================================================
-- 1. _smoke_r3a_subscribe_context
-- 2. _smoke_r3a_subscribe_resource
-- 3. _smoke_r3a_activity_feed
-- 4. _smoke_r3a_stakeholder
-- 5. _smoke_r3a_trust_edge
-- 6. _smoke_r3a_feed_ranking
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- Helper: build a fresh person actor via the existing helper.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public._smoke_r3a_subscribe_context()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid;
  v_papa uuid;
  v_ctx uuid;
  v_sub_id uuid;
  v_list jsonb;
  v_active int;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r3a_subctx Jose', '+520000003011', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, 'r3a_subctx Papa', '+520000003012', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx := (public.create_context('R3A Nave Industrial', 'collective', 'project')->>'context_actor_id')::uuid;

  -- Papá se suscribe al contexto
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  v_sub_id := public.subscribe('context', v_ctx, 'follow', null);
  if v_sub_id is null then raise exception 'r3a_subctx C1: subscribe devolvió NULL'; end if;

  -- list_my_subscriptions: aparece
  v_list := public.list_my_subscriptions();
  if jsonb_array_length(v_list->'subscriptions') = 0 then
    raise exception 'r3a_subctx C2: list_my_subscriptions vacío';
  end if;

  -- Idempotencia: segundo subscribe NO duplica
  perform public.subscribe('context', v_ctx, 'follow', null);
  select count(*)::int into v_active
    from public.subscriptions s
   where s.subscriber_actor_id = v_papa and s.target_actor_id = v_ctx and s.removed_at is null;
  if v_active <> 1 then raise exception 'r3a_subctx C3: idempotencia falló — % filas activas', v_active; end if;

  -- Unsubscribe
  if not public.unsubscribe(v_sub_id) then raise exception 'r3a_subctx C4: unsubscribe false'; end if;
  -- Idempotente: segundo unsubscribe = false (ya removida)
  if public.unsubscribe(v_sub_id) then raise exception 'r3a_subctx C5: unsubscribe doble debería ser false'; end if;

  -- Resubscribe reactiva
  v_sub_id := public.subscribe('context', v_ctx, 'watch', null);
  if v_sub_id is null then raise exception 'r3a_subctx C6: resubscribe falló'; end if;

  -- list_my_subscriptions del founder NO incluye la de Papá (RLS)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_list := public.list_my_subscriptions();
  if exists (select 1 from jsonb_array_elements(v_list->'subscriptions') s where (s->>'id')::uuid = v_sub_id) then
    raise exception 'r3a_subctx C7: RLS leak — José ve subscription de Papá';
  end if;
end; $$;

revoke all on function public._smoke_r3a_subscribe_context() from public, anon;
grant execute on function public._smoke_r3a_subscribe_context() to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r3a_subscribe_resource()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_ctx uuid; v_resource jsonb; v_resource_id uuid;
  v_sub_id uuid;
  v_invalid_targets text[] := array['blob','member','unknown'];
  v_bad text;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r3a_subres Jose', '+520000003021', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, 'r3a_subres Papa', '+520000003022', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx := (public.create_context('R3A Casa Valle', 'collective', 'friend_group')->>'context_actor_id')::uuid;
  v_resource := public.create_resource(v_ctx, 'house', 'Casa Valle R3A');
  v_resource_id := (v_resource->>'id')::uuid;

  -- Papá se suscribe al recurso (sin necesidad de ser miembro del contexto)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  v_sub_id := public.subscribe('resource', v_resource_id, 'watch', 'Papá observa');
  if v_sub_id is null then raise exception 'r3a_subres C1: subscribe(resource) NULL'; end if;

  -- target_type invalido → error
  foreach v_bad in array v_invalid_targets loop
    begin
      perform public.subscribe(v_bad, v_resource_id, 'watch', null);
      raise exception 'r3a_subres C2: subscribe(%) debió fallar', v_bad;
    exception when sqlstate '22023' then
      -- ok
      null;
    end;
  end loop;

  -- subscription_type invalido → error
  begin
    perform public.subscribe('resource', v_resource_id, 'liked', null);
    raise exception 'r3a_subres C3: subscription_type=liked debió fallar';
  exception when sqlstate '22023' then null;
  end;
end; $$;

revoke all on function public._smoke_r3a_subscribe_resource() from public, anon;
grant execute on function public._smoke_r3a_subscribe_resource() to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r3a_activity_feed()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_ctx uuid;
  v_code text;
  v_feed jsonb;
  v_count int;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r3a_feed Jose', '+520000003031', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, 'r3a_feed Papa', '+520000003032', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx := (public.create_context('R3A Feed Ctx', 'collective', 'project')->>'context_actor_id')::uuid;

  -- José crea un recurso (genera activity en v_ctx)
  perform public.create_resource(v_ctx, 'property', 'Recurso Feed R3A');

  -- Papá se suscribe a v_ctx → su feed incluye eventos de v_ctx
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.subscribe('context', v_ctx, 'follow', null);

  v_feed := public.activity_feed(null, 50);
  if jsonb_array_length(v_feed->'feed') = 0 then
    raise exception 'r3a_feed C1: feed vacío tras subscribe';
  end if;

  -- Cada item lleva source + score
  if exists (
    select 1 from jsonb_array_elements(v_feed->'feed') i
    where i->>'source' is null or i->>'score' is null
  ) then
    raise exception 'r3a_feed C2: feed item sin source o score';
  end if;

  -- Sin suscripción ni membership, otro actor no debe ver eventos de v_ctx
  declare v_auth_otro uuid := gen_random_uuid(); v_otro uuid; begin
    v_otro := public._create_person_actor_for_auth_user(v_auth_otro, 'r3a_feed Otro', '+520000003033', null);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_otro::text)::text, true);
    v_feed := public.activity_feed(null, 50);
    if exists (
      select 1 from jsonb_array_elements(v_feed->'feed') i
      where (i->>'context_actor_id')::uuid = v_ctx
    ) then
      raise exception 'r3a_feed C3: actor sin sub/membership ve eventos de v_ctx';
    end if;
  end;

  -- p_actor_id != caller → falla
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  begin
    perform public.activity_feed(v_jose, 50);
    raise exception 'r3a_feed C4: activity_feed(otro_actor) debió fallar';
  exception when sqlstate '42501' then null;
  end;
end; $$;

revoke all on function public._smoke_r3a_activity_feed() from public, anon;
grant execute on function public._smoke_r3a_activity_feed() to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r3a_stakeholder()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_ctx uuid;
  v_sub_id uuid;
  v_evt_count int;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r3a_stk Jose', '+520000003041', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, 'r3a_stk Papa', '+520000003042', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx := (public.create_context('R3A Stakeholder', 'collective', 'project')->>'context_actor_id')::uuid;

  -- Papá se marca como stakeholder del contexto
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  v_sub_id := public.mark_as_stakeholder('context', v_ctx, null);
  if v_sub_id is null then raise exception 'r3a_stk C1: mark_as_stakeholder null'; end if;

  -- subscription_type = stakeholder
  if not exists (
    select 1 from public.subscriptions
     where id = v_sub_id and subscription_type = 'stakeholder' and removed_at is null
  ) then
    raise exception 'r3a_stk C2: row con tipo stakeholder no encontrada';
  end if;

  -- Activity event emitido con event_type = stakeholder.added
  select count(*)::int into v_evt_count
    from public.activity_events
   where context_actor_id = v_ctx
     and event_type = 'stakeholder.added'
     and subject_id = v_sub_id;
  if v_evt_count <> 1 then
    raise exception 'r3a_stk C3: esperaba 1 stakeholder.added, encontró %', v_evt_count;
  end if;

  -- mark_as_stakeholder a nombre de OTRO actor → rechaza
  begin
    perform public.mark_as_stakeholder('context', v_ctx, v_jose);
    raise exception 'r3a_stk C4: mark_as_stakeholder(otro) debió fallar';
  exception when sqlstate '42501' then null;
  end;

  -- Unsubscribe emite stakeholder.removed
  perform public.unsubscribe(v_sub_id);
  select count(*)::int into v_evt_count
    from public.activity_events
   where context_actor_id = v_ctx and event_type = 'stakeholder.removed';
  if v_evt_count <> 1 then
    raise exception 'r3a_stk C5: esperaba 1 stakeholder.removed, encontró %', v_evt_count;
  end if;
end; $$;

revoke all on function public._smoke_r3a_stakeholder() from public, anon;
grant execute on function public._smoke_r3a_stakeholder() to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r3a_trust_edge()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_id uuid;
  v_net jsonb;
  v_lvl int;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r3a_trust Jose', '+520000003051', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, 'r3a_trust Papa', '+520000003052', null);

  -- José declara trust = 5 hacia Papá (personal)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_id := public.add_trust(v_papa, 5, 'personal', 'mi viejo');
  if v_id is null then raise exception 'r3a_trust C1: add_trust null'; end if;

  -- Trust hacia sí mismo → rechaza
  begin
    perform public.add_trust(v_jose, 3, 'personal', null);
    raise exception 'r3a_trust C2: trust hacia sí mismo debió fallar';
  exception when sqlstate '22023' then null;
  end;

  -- Trust level fuera de rango → rechaza
  begin
    perform public.add_trust(v_papa, 6, 'personal', null);
    raise exception 'r3a_trust C3: level=6 debió fallar';
  exception when sqlstate '22023' then null;
  end;

  -- Idempotencia: re-add con mismo (target, type) actualiza, no duplica
  perform public.add_trust(v_papa, 4, 'personal', null);
  select trust_level into v_lvl
    from public.trust_edges
   where source_actor_id = v_jose and target_actor_id = v_papa and trust_type = 'personal' and removed_at is null;
  if v_lvl <> 4 then raise exception 'r3a_trust C4: esperaba level=4 tras update, vio %', v_lvl; end if;

  -- list_trust_network outgoing incluye Papá
  v_net := public.list_trust_network(null);
  if jsonb_array_length(v_net->'outgoing') = 0 then
    raise exception 'r3a_trust C5: outgoing vacío';
  end if;

  -- Papá lo ve en incoming
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  v_net := public.list_trust_network(null);
  if jsonb_array_length(v_net->'incoming') = 0 then
    raise exception 'r3a_trust C6: incoming de Papá vacío';
  end if;

  -- remove_trust como Papá (no source) → false
  if public.remove_trust(v_id) then raise exception 'r3a_trust C7: Papá no debería poder remover trust de José'; end if;

  -- remove_trust como José → true
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  if not public.remove_trust(v_id) then raise exception 'r3a_trust C8: José debería poder remover su trust'; end if;
  -- Idempotente
  if public.remove_trust(v_id) then raise exception 'r3a_trust C9: segundo remove debería ser false'; end if;
end; $$;

revoke all on function public._smoke_r3a_trust_edge() from public, anon;
grant execute on function public._smoke_r3a_trust_edge() to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r3a_feed_ranking()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_papa uuid := gen_random_uuid();
  v_jose uuid; v_papa uuid;
  v_ctx_high uuid;
  v_ctx_low uuid;
  v_feed jsonb;
  v_first_score int;
  v_first_ctx uuid;
  v_last_score int;
begin
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'r3a_rank Jose', '+520000003061', null);
  v_papa := public._create_person_actor_for_auth_user(v_auth_papa, 'r3a_rank Papa', '+520000003062', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx_high := (public.create_context('R3A Ranking High', 'collective', 'project')->>'context_actor_id')::uuid;
  v_ctx_low  := (public.create_context('R3A Ranking Low',  'collective', 'project')->>'context_actor_id')::uuid;
  -- Generar eventos en ambos contextos
  perform public.create_resource(v_ctx_high, 'property', 'Recurso High');
  perform public.create_resource(v_ctx_low,  'property', 'Recurso Low');

  -- Papá: stakeholder en HIGH (score=80), follow en LOW (score=30)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  perform public.subscribe('context', v_ctx_high, 'stakeholder', null);
  perform public.subscribe('context', v_ctx_low,  'follow',      null);

  v_feed := public.activity_feed(null, 50);
  if jsonb_array_length(v_feed->'feed') < 2 then
    raise exception 'r3a_rank C1: esperaba >=2 items, vio %', jsonb_array_length(v_feed->'feed');
  end if;

  -- El primer item es del contexto HIGH y tiene score=80
  v_first_score := ((v_feed->'feed'->0)->>'score')::int;
  v_first_ctx   := ((v_feed->'feed'->0)->>'context_actor_id')::uuid;
  if v_first_score <> 80 then
    raise exception 'r3a_rank C2: primer item score esperaba 80, vio %', v_first_score;
  end if;
  if v_first_ctx <> v_ctx_high then
    raise exception 'r3a_rank C3: primer item esperaba ctx HIGH, vio %', v_first_ctx;
  end if;

  -- Cualquier item con score=30 está después de cualquier item con score=80
  if exists (
    select 1
      from jsonb_array_elements(v_feed->'feed') with ordinality as t(item, idx)
     where (item->>'score')::int = 30
       and idx < (
         select min(idx2)
           from jsonb_array_elements(v_feed->'feed') with ordinality as t2(item2, idx2)
          where (item2->>'score')::int = 80
       )
  ) then
    raise exception 'r3a_rank C4: orden incorrecto — score=30 antes de score=80';
  end if;
end; $$;

revoke all on function public._smoke_r3a_feed_ranking() from public, anon;
grant execute on function public._smoke_r3a_feed_ranking() to authenticated, service_role;
