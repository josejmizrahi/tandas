-- ============================================================================
-- R.5A.B.2 smoke fixup: legacy resource_can(house, reservable) = true
-- (R.2M-3 seed). El point R.5A es justamente que primary_residence NO lo es.
-- La divergencia legacy vs. R.5A se valida en C14 (nueva).
-- ============================================================================
create or replace function public._smoke_r5a_b2_effective_capabilities()
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
  v_res uuid;
  v_caps jsonb;
  v_effective text[];
  v_defaults text[];
begin
  -- C1: capabilities catalog total = 42 (15 vivas + 27 nuevas R.5A.B.2)
  select count(*) into v_count from public.resource_capabilities_catalog;
  if v_count <> 42 then
    raise exception 'r5a.b2 C1: expected 42 capabilities, got %', v_count; end if;

  -- C2: founder-canon new caps presentes
  if not exists (select 1 from public.resource_capabilities_catalog where capability_key='ownable') then
    raise exception 'r5a.b2 C2a: capability ownable missing'; end if;
  if not exists (select 1 from public.resource_capabilities_catalog where capability_key='leasable') then
    raise exception 'r5a.b2 C2b: capability leasable missing'; end if;
  if not exists (select 1 from public.resource_capabilities_catalog where capability_key='splittable') then
    raise exception 'r5a.b2 C2c: capability splittable missing'; end if;

  -- C3: subtype defaults seed cubre los 42 subtypes
  select count(distinct subtype_key) into v_count from public.resource_subtype_capabilities;
  if v_count <> 42 then
    raise exception 'r5a.b2 C3: defaults missing for % subtypes', 42 - v_count; end if;

  -- C4: founder-canon defaults exactos (spec sec 6)
  select array_agg(capability_key order by capability_key) into v_defaults
    from public.resource_subtype_capabilities where subtype_key = 'primary_residence';
  if v_defaults <> array['auditable','documentable','insurable','location_bound','maintainable','ownable','payable','taxable']::text[] then
    raise exception 'r5a.b2 C4a: primary_residence defaults mismatch: %', v_defaults; end if;
  if 'reservable' = any(v_defaults) then
    raise exception 'r5a.b2 C4b: primary_residence INCLUYE reservable (founder NO)'; end if;

  select array_agg(capability_key order by capability_key) into v_defaults
    from public.resource_subtype_capabilities where subtype_key = 'vacation_home';
  if not ('reservable' = any(v_defaults) and 'chargeable' = any(v_defaults) and 'shareable' = any(v_defaults)) then
    raise exception 'r5a.b2 C4c: vacation_home missing reservable/chargeable/shareable'; end if;

  select array_agg(capability_key) into v_defaults
    from public.resource_subtype_capabilities where subtype_key = 'warehouse';
  if not ('leasable' = any(v_defaults) and 'income_generating' = any(v_defaults)) then
    raise exception 'r5a.b2 C4d: warehouse missing leasable/income_generating'; end if;

  select array_agg(capability_key order by capability_key) into v_defaults
    from public.resource_subtype_capabilities where subtype_key = 'money_pool';
  if v_defaults <> array['auditable','chargeable','documentable','governable','payable','settleable','splittable']::text[] then
    raise exception 'r5a.b2 C4e: money_pool defaults mismatch: %', v_defaults; end if;

  select array_agg(capability_key) into v_defaults
    from public.resource_subtype_capabilities where subtype_key = 'recurring_event';
  if not ('schedulable' = any(v_defaults) and 'recurring' = any(v_defaults) and 'closeable' = any(v_defaults)
          and 'payable' = any(v_defaults) and 'splittable' = any(v_defaults) and 'reservable' = any(v_defaults)
          and 'rule_bound' = any(v_defaults) and 'votable' = any(v_defaults) and 'auditable' = any(v_defaults)) then
    raise exception 'r5a.b2 C4f: recurring_event founder canon incomplete'; end if;

  select array_agg(capability_key order by capability_key) into v_defaults
    from public.resource_subtype_capabilities where subtype_key = 'contract';
  if v_defaults <> array['approvable','auditable','documentable','shareable','signable','versionable']::text[] then
    raise exception 'r5a.b2 C4g: contract defaults mismatch: %', v_defaults; end if;

  select array_agg(capability_key order by capability_key) into v_defaults
    from public.resource_subtype_capabilities where subtype_key = 'iou';
  if v_defaults <> array['auditable','disputable','expirable','payable','settleable']::text[] then
    raise exception 'r5a.b2 C4h: iou defaults mismatch: %', v_defaults; end if;

  -- C5: setup contexto + recurso + segundo actor para tests RPC
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_b2 A', '+520000000951', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_b2 B', '+520000000952', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_b2 ctx', 'collective', 'project'))->>'context_actor_id';
  v_res := (public.create_resource(v_ctx, 'house', '_smoke_b2 casa', null, null, 'MXN', '{}'::jsonb))->>'resource_id';

  -- C6: effective_resource_capabilities devuelve defaults de primary_residence
  v_caps := public.effective_resource_capabilities(v_res);
  if v_caps->>'class_key' <> 'real_estate' then
    raise exception 'r5a.b2 C6a: descriptor class_key wrong: %', v_caps->>'class_key'; end if;
  if v_caps->>'subtype_key' <> 'primary_residence' then
    raise exception 'r5a.b2 C6b: descriptor subtype_key wrong: %', v_caps->>'subtype_key'; end if;
  select array_agg(value::text order by value::text) into v_effective
    from jsonb_array_elements_text(v_caps->'effective');
  if v_effective <> array['auditable','documentable','insurable','location_bound','maintainable','ownable','payable','taxable']::text[] then
    raise exception 'r5a.b2 C6c: effective != defaults pre-override: %', v_effective; end if;

  -- C7: set override enabled=true para reservable -> aparece en effective
  perform public.set_resource_capability_override(v_res, 'reservable', true, 'founder allowed');
  v_caps := public.effective_resource_capabilities(v_res);
  select array_agg(value::text) into v_effective from jsonb_array_elements_text(v_caps->'effective');
  if not ('reservable' = any(v_effective)) then
    raise exception 'r5a.b2 C7: enabled override no aparece en effective'; end if;

  -- C8: set override enabled=false para auditable -> desaparece
  perform public.set_resource_capability_override(v_res, 'auditable', false, 'temp disable for test');
  v_caps := public.effective_resource_capabilities(v_res);
  select array_agg(value::text) into v_effective from jsonb_array_elements_text(v_caps->'effective');
  if 'auditable' = any(v_effective) then
    raise exception 'r5a.b2 C8: disabled override no removio auditable'; end if;

  -- C9: overrides array tiene 2 entradas
  if jsonb_array_length(v_caps->'overrides') <> 2 then
    raise exception 'r5a.b2 C9: overrides len wrong, expected 2 got %', jsonb_array_length(v_caps->'overrides'); end if;

  -- C10: upsert (segundo set override de auditable=true) elimina la deshabilitacion
  perform public.set_resource_capability_override(v_res, 'auditable', true, 're-enable');
  v_caps := public.effective_resource_capabilities(v_res);
  select array_agg(value::text) into v_effective from jsonb_array_elements_text(v_caps->'effective');
  if not ('auditable' = any(v_effective)) then
    raise exception 'r5a.b2 C10: re-upsert auditable=true no se aplico'; end if;

  -- C11: capability_key invalido es rechazado
  v_caught := false;
  begin
    perform public.set_resource_capability_override(v_res, '_invalid_cap', true, null);
  exception when others then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b2 C11: capability_key invalido no fue rechazado'; end if;

  -- C12: actor B sin membership es rechazado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.effective_resource_capabilities(v_res);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b2 C12a: non-member pudo leer effective'; end if;

  v_caught := false;
  begin
    perform public.set_resource_capability_override(v_res, 'reservable', false, null);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b2 C12b: non-member pudo setear override'; end if;

  -- C13: RPCs vivos siguen intactos (legacy behavior PRESERVED)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  if jsonb_typeof((public.resource_detail(v_res))->'resource') <> 'object' then
    raise exception 'r5a.b2 C13a: resource_detail rompio'; end if;
  -- resource_can lee resource_type_capabilities legacy. Para house es reservable=true (R.2M-3).
  if not public.resource_can(v_res, 'reservable') then
    raise exception 'r5a.b2 C13b: legacy resource_can(house, reservable) NO debe haber cambiado'; end if;

  -- C14: divergencia documentada -- legacy say reservable, R.5A subtype primary_residence say NO
  --      (pre-override). Esto es el comportamiento esperado: legacy = type, R.5A = subtype.
  delete from public.resource_capability_overrides where resource_id = v_res;
  v_caps := public.effective_resource_capabilities(v_res);
  select array_agg(value::text) into v_effective from jsonb_array_elements_text(v_caps->'effective');
  if 'reservable' = any(v_effective) then
    raise exception 'r5a.b2 C14: primary_residence pre-override INCLUYE reservable (founder NO)'; end if;
  if not public.resource_can(v_res, 'reservable') then
    raise exception 'r5a.b2 C14: legacy DEBE seguir diciendo reservable=true (paralelo, no roto)'; end if;

  -- cleanup best-effort
  begin
    delete from public.resource_capability_overrides where resource_id = v_res;
    delete from public.resources where id = v_res;
    delete from public.actor_memberships where context_actor_id = v_ctx;
    delete from public.actors where id = v_ctx;
    delete from public.actors where id in (v_a, v_b);
  exception when others then null; end;

  raise notice '_smoke_r5a_b2_effective_capabilities OK (catalog 42 + defaults 42 subtypes + RPC effective formula + override CRUD + permission gate + legacy vs R.5A divergencia documentada)';
end;
$$;

revoke all on function public._smoke_r5a_b2_effective_capabilities() from public, anon;
grant execute on function public._smoke_r5a_b2_effective_capabilities() to authenticated, service_role;
