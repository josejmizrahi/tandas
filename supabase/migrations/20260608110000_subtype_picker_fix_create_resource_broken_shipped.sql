-- 🚨 P0 Fix — `create_resource` 10-arg variant shipped broken con Subtype Picker (2026-06-07).
--
-- Bug history: la mig `subtype_picker_create_resource_accepts_subtype` agregó un overload
-- de 10-args (con p_subtype_key) pero el cuerpo del INSERT:
--   1. Referencia column `resources.context_actor_id` que NO EXISTE (la column real es `canonical_owner_actor_id`)
--   2. NO incluye `client_id` → pierde idempotency dedup por client_id (que el 9-arg sí tenía)
--   3. Returns `uuid` directamente; iOS decodea `ResourceCreated{resource_id, resource}` (shape jsonb del 9-arg)
--
-- Detectado durante R.6.B smoke 2026-06-08 al intentar invocar create_resource via trigger.
-- iOS habría crasheado en el INSERT — iOS no probó crear recurso end-to-end con el flow nuevo
-- Subtype Picker después del install 2026-06-07.
--
-- Fix: DROP + CREATE matching la estructura del 9-arg + subtype handling. Misma shape de
-- return jsonb. Idempotency_by_client_id preservada. GRANT execute restaurado.

drop function if exists public.create_resource(
  uuid, text, text, text, numeric, text, jsonb, text, text, text
);

create function public.create_resource(
  p_context_actor_id uuid,
  p_resource_type text,
  p_display_name text,
  p_description text default null,
  p_estimated_value numeric default null,
  p_currency text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null,
  p_location_text text default null,
  p_subtype_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_owner uuid;
  v_id uuid;
  v_existing uuid;
  v_resource_type text := p_resource_type;
  v_location text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  v_owner := coalesce(p_context_actor_id, v_caller);

  if not public.has_actor_authority(v_owner, v_caller, 'resources.create') then
    raise exception 'not authorized to create resources in context %', v_owner using errcode = '42501';
  end if;

  -- Subtype-first path: deriva resource_type del catalog si subtype_key dado.
  if p_subtype_key is not null then
    v_resource_type := public._resource_type_for_subtype(p_subtype_key);
    if v_resource_type is null then
      raise exception 'unknown subtype_key: %', p_subtype_key using errcode = '22023';
    end if;
  end if;

  -- Idempotency by client_id (preserva del 9-arg variant).
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
    (resource_type, resource_subtype_key, display_name, description, estimated_value, currency,
     created_by_actor_id, canonical_owner_actor_id, metadata, client_id, location_text)
  values
    (v_resource_type, p_subtype_key, btrim(p_display_name),
     nullif(btrim(coalesce(p_description, '')), ''),
     p_estimated_value, p_currency,
     v_caller, v_owner, coalesce(p_metadata, '{}'::jsonb), p_client_id, v_location)
  returning id into v_id;

  perform public._emit_activity(v_owner, v_caller, 'resource.created', 'resource', v_id,
    jsonb_build_object(
      'resource_type', v_resource_type,
      'resource_subtype_key', p_subtype_key,
      'display_name', btrim(p_display_name)
    ),
    p_resource_id := v_id);

  return jsonb_build_object('resource_id', v_id,
    'resource', (select to_jsonb(r) from public.resources r where r.id = v_id));
end;
$$;

-- DROP + CREATE perdió el GRANT. Restaurar.
grant execute on function public.create_resource(
  uuid, text, text, text, numeric, text, jsonb, text, text, text
) to authenticated;
