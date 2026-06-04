-- F.RESOURCE.4 — recursos pueden tener ubicación.
-- Founder doctrine 2026-06-04: "agrega la seccion de la ubicacion en
-- resource detail". A diferencia de eventos, NO es obligatoria (cuentas
-- bancarias, juegos digitales, etc. no la necesitan).

alter table public.resources
  add column if not exists location_text text;

drop function if exists public.create_resource(
  uuid, text, text, text, numeric, text, jsonb, text
);
drop function if exists public.update_resource(
  uuid, text, text, numeric, text, jsonb
);

create or replace function public.create_resource(
  p_context_actor_id uuid,
  p_resource_type text,
  p_display_name text,
  p_description text default null,
  p_estimated_value numeric default null,
  p_currency text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null,
  p_location_text text default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_owner uuid;
  v_id uuid;
  v_existing uuid;
  v_location text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  v_owner := coalesce(p_context_actor_id, v_caller);

  if not public.has_actor_authority(v_owner, v_caller, 'resources.create') then
    raise exception 'not authorized to create resources in context %', v_owner using errcode = '42501';
  end if;

  if p_client_id is not null then
    select id into v_existing from public.resources
     where created_by_actor_id = v_caller and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('resource_id', v_existing,
        'resource', (select to_jsonb(r) from public.resources r where r.id = v_existing));
    end if;
  end if;

  v_location := nullif(btrim(coalesce(p_location_text, '')), '');

  insert into public.resources
    (resource_type, display_name, description, estimated_value, currency,
     created_by_actor_id, canonical_owner_actor_id, metadata, client_id, location_text)
  values
    (p_resource_type, btrim(p_display_name), p_description, p_estimated_value, p_currency,
     v_caller, v_owner, coalesce(p_metadata, '{}'::jsonb), p_client_id, v_location)
  returning id into v_id;

  perform public._emit_activity(v_owner, v_caller, 'resource.created', 'resource', v_id,
    jsonb_build_object('resource_type', p_resource_type, 'display_name', btrim(p_display_name)),
    p_resource_id := v_id);

  return jsonb_build_object('resource_id', v_id,
    'resource', (select to_jsonb(r) from public.resources r where r.id = v_id));
end; $$;

create or replace function public.update_resource(
  p_resource_id uuid,
  p_display_name text default null,
  p_description text default null,
  p_estimated_value numeric default null,
  p_currency text default null,
  p_metadata jsonb default null,
  p_location_text text default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.resources%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_r from public.resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found' using errcode = 'P0002'; end if;

  if not (
    public.actor_has_right(v_caller, p_resource_id, 'OWN')
    or public.actor_has_right(v_caller, p_resource_id, 'MANAGE')
    or (v_r.canonical_owner_actor_id is not null
        and public.has_actor_authority(v_r.canonical_owner_actor_id, v_caller, 'resources.manage'))
  ) then
    raise exception 'not authorized to update resource %', p_resource_id using errcode = '42501';
  end if;

  update public.resources
     set display_name = coalesce(btrim(p_display_name), display_name),
         description = coalesce(p_description, description),
         estimated_value = coalesce(p_estimated_value, estimated_value),
         currency = coalesce(p_currency, currency),
         metadata = case when p_metadata is not null then metadata || p_metadata else metadata end,
         -- F.RESOURCE.4: null = no cambiar; '' = limpiar; otro = setear.
         location_text = case
           when p_location_text is null then location_text
           when btrim(p_location_text) = '' then null
           else btrim(p_location_text)
         end
   where id = p_resource_id;

  perform public._emit_activity(v_r.canonical_owner_actor_id, v_caller, 'resource.updated', 'resource', p_resource_id,
    '{}'::jsonb, p_resource_id := p_resource_id);

  return jsonb_build_object('resource',
    (select to_jsonb(r) from public.resources r where r.id = p_resource_id));
end; $$;

revoke all on function public.create_resource(
  uuid, text, text, text, numeric, text, jsonb, text, text
) from public, anon;
grant execute on function public.create_resource(
  uuid, text, text, text, numeric, text, jsonb, text, text
) to authenticated, service_role;

revoke all on function public.update_resource(
  uuid, text, text, numeric, text, jsonb, text
) from public, anon;
grant execute on function public.update_resource(
  uuid, text, text, numeric, text, jsonb, text
) to authenticated, service_role;
