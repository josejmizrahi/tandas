create or replace function public._smoke_r5a_b3_resource_relations()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_count int;
  v_caught boolean;
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid;
  v_ctx uuid;
  v_res_parent uuid;
  v_res_child uuid;
  v_res_third uuid;
  v_relation_id uuid;
  v_result jsonb;
  v_listing jsonb;
  v_created boolean;
begin
  -- C1: catalogo de 15 relation_types seedeado con founder canon
  select count(*) into v_count from public.resource_relation_types;
  if v_count <> 15 then
    raise exception 'r5a.b3 C1: expected 15 relation_types, got %', v_count; end if;

  -- C2: founder canon presente (contains, documents, secures, owns, leases, insures)
  if not exists (select 1 from public.resource_relation_types where relation_type='contains') then
    raise exception 'r5a.b3 C2a: relation_type contains missing'; end if;
  if not exists (select 1 from public.resource_relation_types where relation_type='documents') then
    raise exception 'r5a.b3 C2b: relation_type documents missing'; end if;
  if not exists (select 1 from public.resource_relation_types where relation_type='secures') then
    raise exception 'r5a.b3 C2c: relation_type secures missing'; end if;
  if not exists (select 1 from public.resource_relation_types where relation_type='owns') then
    raise exception 'r5a.b3 C2d: relation_type owns missing'; end if;

  -- C3: tabla con RLS
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname='resource_relations' and c.relrowsecurity=true) then
    raise exception 'r5a.b3 C3: RLS not enabled on resource_relations'; end if;

  -- C4: setup contexto + 3 recursos (parent=Casa, child=Escritura, third=Seguro)
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_b3 A', '+520000000941', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_b3 B', '+520000000942', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_b3 ctx', 'collective', 'project'))->>'context_actor_id';
  v_res_parent := (public.create_resource(v_ctx, 'house',    '_smoke_b3 Casa Acapulco',     null, null, 'MXN', '{}'::jsonb))->>'resource_id';
  v_res_child  := (public.create_resource(v_ctx, 'contract', '_smoke_b3 Escritura',         null, null, 'MXN', '{}'::jsonb))->>'resource_id';
  v_res_third  := (public.create_resource(v_ctx, 'contract', '_smoke_b3 Seguro Casa',       null, null, 'MXN', '{}'::jsonb))->>'resource_id';

  -- C5: set_resource_relation crea (Casa documents Escritura) -- created=true
  v_result := public.set_resource_relation(v_res_parent, v_res_child, 'documents', '{"note":"original"}'::jsonb);
  v_relation_id := (v_result->>'relation_id')::uuid;
  v_created := (v_result->>'created')::boolean;
  if v_relation_id is null then raise exception 'r5a.b3 C5a: set no devolvio relation_id'; end if;
  if not v_created then raise exception 'r5a.b3 C5b: created flag should be true on first insert'; end if;

  -- C6: re-set con misma (parent, child, type) es idempotente, devuelve same id, created=false
  v_result := public.set_resource_relation(v_res_parent, v_res_child, 'documents', '{"note":"updated"}'::jsonb);
  if (v_result->>'relation_id')::uuid <> v_relation_id then
    raise exception 'r5a.b3 C6a: upsert no preservo relation_id'; end if;
  if (v_result->>'created')::boolean then
    raise exception 'r5a.b3 C6b: created flag should be false on update'; end if;
  -- metadata se actualizo
  if (select metadata->>'note' from public.resource_relations where id = v_relation_id) <> 'updated' then
    raise exception 'r5a.b3 C6c: metadata no se actualizo en upsert'; end if;

  -- C7: agregar segunda relation (Casa secures Seguro) -- distinto type
  perform public.set_resource_relation(v_res_parent, v_res_third, 'insures', '{}'::jsonb);
  select count(*) into v_count from public.resource_relations where parent_resource_id = v_res_parent;
  if v_count <> 2 then raise exception 'r5a.b3 C7: expected 2 outbound, got %', v_count; end if;

  -- C8: list_resource_relations devuelve outbound 2 + inbound 0 desde el padre
  v_listing := public.list_resource_relations(v_res_parent);
  if jsonb_array_length(v_listing->'outbound') <> 2 then
    raise exception 'r5a.b3 C8a: outbound length wrong: %', jsonb_array_length(v_listing->'outbound'); end if;
  if jsonb_array_length(v_listing->'inbound') <> 0 then
    raise exception 'r5a.b3 C8b: inbound should be 0 for parent: %', jsonb_array_length(v_listing->'inbound'); end if;

  -- C9: list desde el hijo Escritura devuelve outbound 0 + inbound 1
  v_listing := public.list_resource_relations(v_res_child);
  if jsonb_array_length(v_listing->'outbound') <> 0 then
    raise exception 'r5a.b3 C9a: child outbound should be 0: %', jsonb_array_length(v_listing->'outbound'); end if;
  if jsonb_array_length(v_listing->'inbound') <> 1 then
    raise exception 'r5a.b3 C9b: child inbound should be 1: %', jsonb_array_length(v_listing->'inbound'); end if;

  -- C10: self-relation rechazada
  v_caught := false;
  begin
    perform public.set_resource_relation(v_res_parent, v_res_parent, 'contains', '{}'::jsonb);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'r5a.b3 C10: self-relation no rechazada'; end if;

  -- C11: relation_type invalido rechazado
  v_caught := false;
  begin
    perform public.set_resource_relation(v_res_parent, v_res_child, '_invalid_type', '{}'::jsonb);
  exception when others then v_caught := true; end;
  if not v_caught then raise exception 'r5a.b3 C11: relation_type invalido no rechazado'; end if;

  -- C12: actor B sin membership rechazado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.list_resource_relations(v_res_parent);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'r5a.b3 C12a: non-member pudo listar relations'; end if;

  v_caught := false;
  begin
    perform public.set_resource_relation(v_res_parent, v_res_child, 'contains', '{}'::jsonb);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then raise exception 'r5a.b3 C12b: non-member pudo setear relation'; end if;

  -- C13: remove_resource_relation borra
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.remove_resource_relation(v_relation_id);
  if not (v_result->>'removed')::boolean then
    raise exception 'r5a.b3 C13a: remove devolvio removed=false'; end if;
  if exists (select 1 from public.resource_relations where id = v_relation_id) then
    raise exception 'r5a.b3 C13b: relation no se borro'; end if;

  -- C14: remove idempotente -- segundo call devuelve not_found, no rompe
  v_result := public.remove_resource_relation(v_relation_id);
  if (v_result->>'removed')::boolean then
    raise exception 'r5a.b3 C14a: re-remove devolvio removed=true para not_found'; end if;
  if v_result->>'reason' <> 'not_found' then
    raise exception 'r5a.b3 C14b: re-remove reason wrong: %', v_result->>'reason'; end if;

  -- C15: cascade delete -- borrar el resource borra sus relations
  perform public.set_resource_relation(v_res_parent, v_res_third, 'contains', '{}'::jsonb);
  select count(*) into v_count from public.resource_relations where parent_resource_id = v_res_parent;
  if v_count = 0 then raise exception 'r5a.b3 C15a: setup pre-cascade fallo'; end if;
  delete from public.resources where id = v_res_third;
  select count(*) into v_count from public.resource_relations where child_resource_id = v_res_third;
  if v_count <> 0 then raise exception 'r5a.b3 C15b: cascade delete no limpio relations huerfanas'; end if;

  -- cleanup best-effort
  begin
    delete from public.resource_relations where parent_resource_id in (v_res_parent, v_res_child);
    delete from public.resources where id in (v_res_parent, v_res_child);
    delete from public.actor_memberships where context_actor_id = v_ctx;
    delete from public.actors where id = v_ctx;
    delete from public.actors where id in (v_a, v_b);
  exception when others then null; end;

  raise notice '_smoke_r5a_b3_resource_relations OK (15 types + table + 3 RPCs CRUD + idempotency + permission gate + self-reject + cascade)';
end;
$$;

revoke all on function public._smoke_r5a_b3_resource_relations() from public, anon;
grant execute on function public._smoke_r5a_b3_resource_relations() to authenticated, service_role;
