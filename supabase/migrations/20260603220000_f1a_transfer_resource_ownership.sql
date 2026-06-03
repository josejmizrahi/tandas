-- F.1A polish — transfer_resource_ownership RPC (atómica).
--
-- Antes: para transferir ownership el caller tenía que llamar grant_right(new) +
-- revoke_right(old) en dos llamadas separadas — un crash entre las dos dejaba
-- al recurso sin dueño o con doble OWN. Este migration agrega un atomic.
--
-- Doctrina:
--  - Caller debe tener al menos un OWN activo en el recurso.
--  - Se revocan TODOS los OWN activos del caller y se reemplazan por un único
--    OWN al recipient con la suma de percent (NULL si todos los del caller
--    eran NULL).
--  - Si el caller era canonical_owner_actor_id, pasa al recipient.
--  - Si recipient == caller → rechazo.
--  - Recipient debe poder ser dueño (capability can_own_resources via actor_can).
--  - Emite right.transferred con payload {from, to, percent_total, reason}.

INSERT INTO public.activity_event_catalog (event_type, domain, description, expected_subject_type, is_system_generated)
VALUES ('right.transferred', 'right', 'Ownership de un recurso transferido a otro actor', 'resource', false)
ON CONFLICT (event_type) DO NOTHING;

CREATE OR REPLACE FUNCTION public.transfer_resource_ownership(
  p_resource_id uuid,
  p_to_actor_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_resource public.resources%rowtype;
  v_recipient public.actors%rowtype;
  v_total_percent numeric;
  v_all_null boolean;
  v_revoked_count int;
  v_new_right_id uuid;
  v_was_canonical boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;
  IF v_caller = p_to_actor_id THEN
    RAISE EXCEPTION 'cannot transfer ownership to yourself' USING errcode = '22023';
  END IF;

  SELECT * INTO v_resource FROM public.resources WHERE id = p_resource_id;
  IF v_resource.id IS NULL THEN
    RAISE EXCEPTION 'resource not found' USING errcode = 'P0002';
  END IF;

  SELECT * INTO v_recipient FROM public.actors WHERE id = p_to_actor_id;
  IF v_recipient.id IS NULL THEN
    RAISE EXCEPTION 'recipient actor not found' USING errcode = 'P0002';
  END IF;

  -- Recipient debe poder ser dueño (R.2S.1 actor capabilities).
  IF NOT public.actor_can(p_to_actor_id, 'can_own_resources') THEN
    RAISE EXCEPTION 'recipient cannot own resources (missing can_own_resources capability)' USING errcode = '42501';
  END IF;

  -- Caller debe tener un OWN activo.
  IF NOT EXISTS (
    SELECT 1 FROM public.resource_rights
    WHERE resource_id = p_resource_id AND holder_actor_id = v_caller
      AND right_kind = 'OWN'
      AND revoked_at IS NULL AND expired_at IS NULL
      AND (starts_at IS NULL OR starts_at <= now())
      AND (ends_at IS NULL OR ends_at > now())
  ) THEN
    RAISE EXCEPTION 'caller has no active OWN right on this resource' USING errcode = '42501';
  END IF;

  -- Sumar percent del caller. Si TODOS son NULL → mantenemos NULL en el destino.
  SELECT bool_and(percent IS NULL), COALESCE(sum(percent), 0)
    INTO v_all_null, v_total_percent
    FROM public.resource_rights
   WHERE resource_id = p_resource_id AND holder_actor_id = v_caller
     AND right_kind = 'OWN' AND revoked_at IS NULL AND expired_at IS NULL
     AND (starts_at IS NULL OR starts_at <= now())
     AND (ends_at IS NULL OR ends_at > now());

  -- Revocar los OWN del caller (soft delete con revoked_at).
  WITH revoked AS (
    UPDATE public.resource_rights
       SET revoked_at = now(),
           updated_at = now(),
           metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
             'transferred_to', p_to_actor_id,
             'transfer_reason', p_reason)
     WHERE resource_id = p_resource_id AND holder_actor_id = v_caller
       AND right_kind = 'OWN' AND revoked_at IS NULL
     RETURNING 1
  )
  SELECT count(*) INTO v_revoked_count FROM revoked;

  -- Otorgar nuevo OWN al recipient. Reutilizamos grant_right para mantener
  -- la lógica de upsert/undelete (R.0C.2b).
  v_new_right_id := (public.grant_right(
    p_resource_id := p_resource_id,
    p_holder_actor_id := p_to_actor_id,
    p_right_kind := 'OWN',
    p_percent := CASE WHEN v_all_null THEN NULL ELSE v_total_percent END,
    p_metadata := jsonb_build_object(
      'transferred_from', v_caller,
      'transfer_reason', p_reason)
  ) ->> 'right_id')::uuid;

  -- Si el caller era el canonical_owner, pasar al recipient.
  v_was_canonical := (v_resource.canonical_owner_actor_id = v_caller);
  IF v_was_canonical THEN
    UPDATE public.resources
       SET canonical_owner_actor_id = p_to_actor_id,
           updated_at = now()
     WHERE id = p_resource_id;
  END IF;

  -- Activity event. Context para el activity: el contexto del canonical_owner
  -- ANTES del transfer si era él, o el actual.
  PERFORM public._emit_activity(
    COALESCE(v_resource.canonical_owner_actor_id, p_to_actor_id),
    v_caller,
    'right.transferred',
    'resource',
    p_resource_id,
    jsonb_build_object(
      'from', v_caller,
      'to', p_to_actor_id,
      'right_kind', 'OWN',
      'percent_total', CASE WHEN v_all_null THEN NULL ELSE v_total_percent END,
      'rights_revoked', v_revoked_count,
      'canonical_owner_changed', v_was_canonical,
      'reason', p_reason
    ),
    p_resource_id := p_resource_id
  );

  RETURN jsonb_build_object(
    'resource_id', p_resource_id,
    'from_actor_id', v_caller,
    'to_actor_id', p_to_actor_id,
    'new_right_id', v_new_right_id,
    'rights_revoked', v_revoked_count,
    'percent_total', CASE WHEN v_all_null THEN NULL ELSE v_total_percent END,
    'canonical_owner_changed', v_was_canonical
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.transfer_resource_ownership(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_resource_ownership(uuid, uuid, text) TO authenticated, service_role;

COMMENT ON FUNCTION public.transfer_resource_ownership(uuid, uuid, text) IS
'F.1A polish — transferencia atómica de ownership. Revoca todos los OWN activos del caller y otorga uno equivalente al recipient. Actualiza canonical_owner_actor_id si el caller era el dominante. Requiere que el recipient tenga can_own_resources.';
