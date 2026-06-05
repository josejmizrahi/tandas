create or replace function public._smoke_r5a_b7_context_descriptor()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caught boolean;
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid;
  v_ctx_project uuid;
  v_ctx_family uuid;
  v_descriptor jsonb;
  v_section_keys text[];
begin
  -- C1: setup
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_b7 A', '+520000000921', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_b7 B', '+520000000922', null);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx_project := (public.create_context('_smoke_b7 Proyecto', 'collective', 'project'))->>'context_actor_id';
  v_ctx_family := (public.create_context('_smoke_b7 Familia', 'collective', 'family'))->>'context_actor_id';

  -- C2: descriptor devuelve jsonb con 16 keys top-level
  v_descriptor := public.context_detail_descriptor(v_ctx_project);
  if jsonb_typeof(v_descriptor) <> 'object' then
    raise exception 'r5a.b7 C2a: descriptor no es object'; end if;
  if not (v_descriptor ?& array['context','membership','roles','permissions','sections','widgets','actions',
                                 'metrics','members_preview','resources_preview','events_preview','money_preview',
                                 'obligations_preview','decisions_preview','documents_preview','activity_preview']) then
    raise exception 'r5a.b7 C2b: descriptor le faltan keys'; end if;

  -- C3: context shape (is_context + actor_subtype=project)
  if (v_descriptor->'context'->>'is_context')::boolean <> true then
    raise exception 'r5a.b7 C3a: context.is_context no es true'; end if;
  if v_descriptor->'context'->>'actor_subtype' <> 'project' then
    raise exception 'r5a.b7 C3b: actor_subtype wrong: %', v_descriptor->'context'->>'actor_subtype'; end if;

  -- C4: sections founder canon project (NO money/obligations, SÍ governance+documents)
  select array_agg(value->>'section_key' order by (value->>'sort_order')::int) into v_section_keys
    from jsonb_array_elements(v_descriptor->'sections');
  if 'money' = any(v_section_keys) then
    raise exception 'r5a.b7 C4a: project INCLUYE money (founder NO): %', v_section_keys; end if;
  if 'obligations' = any(v_section_keys) then
    raise exception 'r5a.b7 C4b: project INCLUYE obligations (founder NO): %', v_section_keys; end if;
  if not ('overview' = any(v_section_keys) and 'people' = any(v_section_keys) and 'resources' = any(v_section_keys)) then
    raise exception 'r5a.b7 C4c: project sin secciones core'; end if;
  if not ('calendar' = any(v_section_keys) and 'documents' = any(v_section_keys)) then
    raise exception 'r5a.b7 C4d: project sin calendar/documents'; end if;

  -- C5: widgets founder canon project
  select array_agg(value->>'widget_key' order by (value->>'sort_order')::int) into v_section_keys
    from jsonb_array_elements(v_descriptor->'widgets');
  if v_section_keys is null or array_length(v_section_keys, 1) = 0 then
    raise exception 'r5a.b7 C5a: widgets empty'; end if;
  if not ('active_projects' = any(v_section_keys) and 'open_decisions' = any(v_section_keys)) then
    raise exception 'r5a.b7 C5b: project widgets sin founder canon: %', v_section_keys; end if;

  -- C6: membership my_permissions es array
  if jsonb_typeof(v_descriptor->'membership'->'my_permissions') <> 'array' then
    raise exception 'r5a.b7 C6: my_permissions no es array'; end if;

  -- C7: family context muestra money + obligations (founder canon)
  v_descriptor := public.context_detail_descriptor(v_ctx_family);
  if v_descriptor->'context'->>'actor_subtype' <> 'family' then
    raise exception 'r5a.b7 C7a: family actor_subtype wrong'; end if;
  select array_agg(value->>'section_key') into v_section_keys
    from jsonb_array_elements(v_descriptor->'sections');
  if not ('money' = any(v_section_keys) and 'obligations' = any(v_section_keys)) then
    raise exception 'r5a.b7 C7b: family descriptor SIN money/obligations: %', v_section_keys; end if;

  -- C8: metrics shape
  if v_descriptor->'metrics'->>'member_count' is null then
    raise exception 'r5a.b7 C8a: metrics.member_count null'; end if;
  if (v_descriptor->'metrics'->>'member_count')::int < 1 then
    raise exception 'r5a.b7 C8b: member_count debe ser >=1 (creator)'; end if;
  if jsonb_typeof(v_descriptor->'metrics'->'resource_count_by_class') <> 'object' then
    raise exception 'r5a.b7 C8c: resource_count_by_class no es object'; end if;

  -- C9: previews son arrays
  if jsonb_typeof(v_descriptor->'members_preview') <> 'array'
     or jsonb_typeof(v_descriptor->'resources_preview') <> 'array'
     or jsonb_typeof(v_descriptor->'events_preview') <> 'array'
     or jsonb_typeof(v_descriptor->'obligations_preview') <> 'array'
     or jsonb_typeof(v_descriptor->'decisions_preview') <> 'array'
     or jsonb_typeof(v_descriptor->'documents_preview') <> 'array'
     or jsonb_typeof(v_descriptor->'activity_preview') <> 'array' then
    raise exception 'r5a.b7 C9: previews no son arrays'; end if;

  -- C10: members_preview incluye al creator
  if jsonb_array_length(v_descriptor->'members_preview') < 1 then
    raise exception 'r5a.b7 C10: members_preview vacio'; end if;

  -- C11: actions es array
  if jsonb_typeof(v_descriptor->'actions') <> 'array' then
    raise exception 'r5a.b7 C11: actions no es array'; end if;

  -- C12: visibility gate -- actor B (non-member) rechazado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_caught := false;
  begin
    perform public.context_detail_descriptor(v_ctx_project);
  exception when insufficient_privilege then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b7 C12: non-member pudo llamar descriptor'; end if;

  -- C13: context_actor_id que no es contexto (e.g. person actor) es rechazado
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_caught := false;
  begin
    perform public.context_detail_descriptor(v_a);
  exception when others then v_caught := true; end;
  if not v_caught then
    raise exception 'r5a.b7 C13: person actor no es rechazado como context'; end if;

  -- cleanup
  begin
    delete from public.actor_memberships where context_actor_id in (v_ctx_project, v_ctx_family);
    delete from public.actors where id in (v_ctx_project, v_ctx_family);
    delete from public.actors where id in (v_a, v_b);
  exception when others then null; end;

  raise notice '_smoke_r5a_b7_context_descriptor OK (16 keys + project vs family canon + my_permissions + metrics + previews + visibility + non-context reject)';
end;
$$;

revoke all on function public._smoke_r5a_b7_context_descriptor() from public, anon;
grant execute on function public._smoke_r5a_b7_context_descriptor() to authenticated, service_role;
