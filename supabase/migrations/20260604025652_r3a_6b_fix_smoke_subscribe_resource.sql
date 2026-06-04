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
  v_resource_id := (v_resource->>'resource_id')::uuid;
  if v_resource_id is null then raise exception 'r3a_subres setup: resource_id null'; end if;

  -- Papá se suscribe al recurso (sin necesidad de ser miembro del contexto)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_papa::text)::text, true);
  v_sub_id := public.subscribe('resource', v_resource_id, 'watch', 'Papá observa');
  if v_sub_id is null then raise exception 'r3a_subres C1: subscribe(resource) NULL'; end if;

  -- target_type invalido → error
  foreach v_bad in array v_invalid_targets loop
    begin
      perform public.subscribe(v_bad, v_resource_id, 'watch', null);
      raise exception 'r3a_subres C2: subscribe(%) debió fallar', v_bad;
    exception when sqlstate '22023' then null;
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
