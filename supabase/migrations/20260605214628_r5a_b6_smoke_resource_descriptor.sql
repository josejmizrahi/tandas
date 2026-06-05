create or replace function public._smoke_r5a_b6_resource_descriptor()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caught boolean;
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid;
  v_ctx uuid;
  v_res uuid;
  v_descriptor jsonb;
  v_section_keys text[];
  v_sect text;
begin
  -- C1: setup
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_b6 A', '+520000000931', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_b6 B', '+520000000932', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_b6 ctx', 'collective', 'project'))->>'context_actor_id';
  v_res := (public.create_resource(v_ctx, 'house', '_smoke_b6 Casa', null, null, 'MXN', '{}'::jsonb))->>'resource_id';

  -- C2: descriptor devuelve jsonb con 17 keys top-level
  v_descriptor := public.resource_detail_descriptor(v_res);
  if jsonb_typeof(v_descriptor) <> 'object' then
    raise exception 'r5a.b6 C2a: descriptor no es object'; end if;
  if not (v_descriptor ?& array['resource','class','subtype','effective_capabilities','rights',
                                 'sections','widgets','actions','action_forms','state','metrics',
                                 'relations','linked_events','linked_documents','linked_obligations',
                                 'linked_decisions','activity_preview']) then
    raise exception 'r5a.b6 C2b: descriptor le faltan keys'; end if;

  -- C3: class y subtype son founder canon
  if v_descriptor->'class'->>'class_key' <> 'real_estate' then
    raise exception 'r5a.b6 C3a: class wrong: %', v_descriptor->'class'->>'class_key'; end if;
  if v_descriptor->'subtype'->>'subtype_key' <> 'primary_residence' then
    raise exception 'r5a.b6 C3b: subtype wrong: %', v_descriptor->'subtype'->>'subtype_key'; end if;

  -- C4: effective_capabilities cubre founder canon de primary_residence (8 caps)
  select array_agg(value::text order by value::text) into v_section_keys
    from jsonb_array_elements_text(v_descriptor->'effective_capabilities');
  if v_section_keys <> array['auditable','documentable','insurable','location_bound','maintainable','ownable','payable','taxable']::text[] then
    raise exception 'r5a.b6 C4: effective_capabilities mismatch: %', v_section_keys; end if;

  -- C5: sections filtradas por capability — primary_residence NO incluye reservations
  select array_agg(value->>'section_key' order by (value->>'sort_order')::int) into v_section_keys
    from jsonb_array_elements(v_descriptor->'sections');
  if v_section_keys is null or array_length(v_section_keys, 1) = 0 then
    raise exception 'r5a.b6 C5a: sections empty'; end if;
  if 'reservations' = any(v_section_keys) then
    raise exception 'r5a.b6 C5b: primary_residence INCLUYE reservations (caps no filtraron)'; end if;
  if not ('overview' = any(v_section_keys) and 'activity' = any(v_section_keys) and 'settings' = any(v_section_keys)) then
    raise exception 'r5a.b6 C5c: sections sin overview/activity/settings'; end if;
  if not ('location' = any(v_section_keys) and 'maintenance' = any(v_section_keys) and 'insurance' = any(v_section_keys)) then
    raise exception 'r5a.b6 C5d: sections sin founder canon real_estate'; end if;

  -- C6: widgets filtradas
  select array_agg(value->>'widget_key' order by (value->>'sort_order')::int) into v_section_keys
    from jsonb_array_elements(v_descriptor->'widgets');
  if v_section_keys is null or array_length(v_section_keys, 1) = 0 then
    raise exception 'r5a.b6 C6a: widgets empty'; end if;
  if not ('resource_value' = any(v_section_keys) and 'recent_activity' = any(v_section_keys)) then
    raise exception 'r5a.b6 C6b: widgets sin founder canon: %', v_section_keys; end if;

  -- C7: rights array (al menos OWN del creator)
  if jsonb_array_length(v_descriptor->'rights') < 1 then
    raise exception 'r5a.b6 C7: rights vacio (esperado al menos OWN auto)'; end if;

  -- C8: actions shape extendido
  if jsonb_typeof(v_descriptor->'actions') <> 'array' then
    raise exception 'r5a.b6 C8a: actions no es array'; end if;
  if exists (select 1 from jsonb_array_elements(v_descriptor->'actions') a
             where not (a ?& array['action_key','mode','form_schema_present','dangerous','confirmation_required'])) then
    raise exception 'r5a.b6 C8b: actions sin shape extendido'; end if;

  -- C9: action_forms es object
  if jsonb_typeof(v_descriptor->'action_forms') <> 'object' then
    raise exception 'r5a.b6 C9: action_forms no es object'; end if;

  -- C10: state shape
  if v_descriptor->'state'->>'status' is null then
    raise exception 'r5a.b6 C10a: state.status null'; end if;
  if (v_descriptor->'state'->>'archived')::boolean <> false then
    raise exception 'r5a.b6 C10b: state.archived debe ser false'; end if;

  -- C11: metrics
  if v_descriptor->'metrics'->>'currency' <> 'MXN' then
    raise exception 'r5a.b6 C11: metrics.currency wrong'; end if;

  -- C12: relations shape
  if jsonb_typeof(v_descriptor->'relations'->'outbound') <> 'array'
     or jsonb_typeof(v_descriptor->'relations'->'inbound') <> 'array' then
    raise exception 'r5a.b6 C12: relations shape wrong'; end if;

  -- C13: linked arrays
  if jsonb_typeof(v_descriptor->'linked_documents') <> 'array' then
    raise exception 'r5a.b6 C13a: linked_documents no es array'; end if;
  if jsonb_typeof(v_descriptor->'linked_events') <> 'array' then
    raise exception 'r5a.b6 C13b: linked_events no es array'; end if;
  if jsonb_typeof(v_descriptor->'activity_preview') <> 'array' then
    raise exception 'r5a.b6 C13c: activity_preview no es array'; end if;

  -- C14: visibility gate -- actor B sin membership es rechazado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.resource_detail_descriptor(v_res);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b6 C14: non-member pudo llamar descriptor'; end if;

  -- C15: cambiar subtype a vacation_home -> descriptor muestra reservations/availability
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  update public.resources set resource_subtype_key = 'vacation_home' where id = v_res;
  v_descriptor := public.resource_detail_descriptor(v_res);
  select array_agg(value->>'section_key') into v_section_keys
    from jsonb_array_elements(v_descriptor->'sections');
  if not ('reservations' = any(v_section_keys)) then
    raise exception 'r5a.b6 C15a: vacation_home descriptor NO muestra reservations'; end if;
  if not ('availability' = any(v_section_keys)) then
    raise exception 'r5a.b6 C15b: vacation_home descriptor NO muestra availability'; end if;

  -- cleanup
  begin
    delete from public.resources where id = v_res;
    delete from public.actor_memberships where context_actor_id = v_ctx;
    delete from public.actors where id = v_ctx;
    delete from public.actors where id in (v_a, v_b);
  exception when others then null; end;

  raise notice '_smoke_r5a_b6_resource_descriptor OK (shape 17 keys + class/subtype + effective + sections filtradas + widgets + rights + actions extendido + state + metrics + relations + visibility gate + subtype switch dinamico)';
end;
$$;

revoke all on function public._smoke_r5a_b6_resource_descriptor() from public, anon;
grant execute on function public._smoke_r5a_b6_resource_descriptor() to authenticated, service_role;
