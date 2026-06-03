-- F.1A polish — update_context RPC.
--
-- Antes: context_settings_summary emitía available_actions ["edit_general",
-- "edit_decisions", "edit_money", "edit_reservations", "edit_invitations"]
-- pero NO existía write RPC para esos slots. iOS no podía cerrar el loop.
-- Este migration agrega el write path.
--
-- Doctrina:
--  - Todos los campos son opcionales — solo se aplica lo que llegue distinto de NULL.
--  - Permisos: context.manage (espeja el available_action "edit_general").
--  - Metadata merge a nivel slot: jsonb passed for decisions_config etc. se
--    fusiona con la existente (||) — el caller solo manda lo que cambia.
--  - Top-level metadata fields (description, image_url) se sobrescriben directo.
--  - actor.display_name + actor.visibility se setean por nombre.
--  - Devuelve context_settings_summary(...) para que el frontend refresque sin extra round-trip.

-- 1. Catalogar el event_type para que _emit_activity no marque uncatalogued.
INSERT INTO public.activity_event_catalog (event_type, domain, description, expected_subject_type, is_system_generated)
VALUES ('context.updated', 'context', 'Settings del contexto fueron actualizadas', 'context', false)
ON CONFLICT (event_type) DO NOTHING;

-- 2. La RPC.
CREATE OR REPLACE FUNCTION public.update_context(
  p_context_actor_id uuid,
  p_display_name text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_visibility text DEFAULT NULL,
  p_image_url text DEFAULT NULL,
  p_decisions_config jsonb DEFAULT NULL,
  p_money_config jsonb DEFAULT NULL,
  p_reservations_config jsonb DEFAULT NULL,
  p_invitations_config jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_actor public.actors%rowtype;
  v_meta jsonb;
  v_fields_changed text[] := ARRAY[]::text[];
  v_new_display_name text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  SELECT * INTO v_actor FROM public.actors WHERE id = p_context_actor_id;
  IF v_actor.id IS NULL THEN
    RAISE EXCEPTION 'context not found' USING errcode = 'P0002';
  END IF;
  IF v_actor.actor_kind = 'person' THEN
    RAISE EXCEPTION 'cannot update personal context via update_context (use update_my_profile)' USING errcode = '22023';
  END IF;
  IF NOT public.has_actor_authority(p_context_actor_id, v_caller, 'context.manage') THEN
    RAISE EXCEPTION 'context.manage required to edit context %', p_context_actor_id USING errcode = '42501';
  END IF;

  -- Validate visibility against actors_visibility_check.
  IF p_visibility IS NOT NULL AND p_visibility NOT IN ('private', 'members', 'public') THEN
    RAISE EXCEPTION 'invalid visibility "%" (allowed: private, members, public)', p_visibility USING errcode = '22023';
  END IF;

  -- Validate display_name not empty when provided.
  IF p_display_name IS NOT NULL THEN
    v_new_display_name := btrim(p_display_name);
    IF v_new_display_name = '' THEN
      RAISE EXCEPTION 'display_name cannot be empty' USING errcode = '22023';
    END IF;
  END IF;

  v_meta := COALESCE(v_actor.metadata, '{}'::jsonb);

  -- Top-level metadata slots (overwrite).
  IF p_description IS NOT NULL THEN
    v_meta := v_meta || jsonb_build_object('description', p_description);
    v_fields_changed := v_fields_changed || ARRAY['description'];
  END IF;
  IF p_image_url IS NOT NULL THEN
    v_meta := v_meta || jsonb_build_object('image_url', p_image_url);
    v_fields_changed := v_fields_changed || ARRAY['image_url'];
  END IF;

  -- Nested configs (deep merge: existing slot overlaid with new keys).
  IF p_decisions_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{decisions_config}',
      COALESCE(v_meta->'decisions_config', '{}'::jsonb) || p_decisions_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['decisions_config'];
  END IF;
  IF p_money_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{money_config}',
      COALESCE(v_meta->'money_config', '{}'::jsonb) || p_money_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['money_config'];
  END IF;
  IF p_reservations_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{reservations_config}',
      COALESCE(v_meta->'reservations_config', '{}'::jsonb) || p_reservations_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['reservations_config'];
  END IF;
  IF p_invitations_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{invitations_config}',
      COALESCE(v_meta->'invitations_config', '{}'::jsonb) || p_invitations_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['invitations_config'];
  END IF;

  IF p_display_name IS NOT NULL THEN
    v_fields_changed := v_fields_changed || ARRAY['display_name'];
  END IF;
  IF p_visibility IS NOT NULL THEN
    v_fields_changed := v_fields_changed || ARRAY['visibility'];
  END IF;

  -- Si nada cambió, devolver el summary actual sin escritura ni emisión.
  IF array_length(v_fields_changed, 1) IS NULL THEN
    RETURN public.context_settings_summary(p_context_actor_id);
  END IF;

  UPDATE public.actors
     SET display_name = COALESCE(v_new_display_name, display_name),
         visibility   = COALESCE(p_visibility, visibility),
         metadata     = v_meta,
         updated_at   = now()
   WHERE id = p_context_actor_id;

  PERFORM public._emit_activity(
    p_context_actor_id, v_caller, 'context.updated', 'context', p_context_actor_id,
    jsonb_build_object('fields_changed', to_jsonb(v_fields_changed))
  );

  RETURN public.context_settings_summary(p_context_actor_id);
END;
$function$;

-- 3. Founder lock R.2S.1: Supabase REVOKE FROM anon por default. Concedemos
--    EXECUTE a authenticated explícitamente.
REVOKE ALL ON FUNCTION public.update_context(uuid, text, text, text, text, jsonb, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_context(uuid, text, text, text, text, jsonb, jsonb, jsonb, jsonb) TO authenticated, service_role;

COMMENT ON FUNCTION public.update_context(uuid, text, text, text, text, jsonb, jsonb, jsonb, jsonb) IS
'F.1A polish — write path para context_settings_summary slots (display_name, visibility, description, image_url, decisions_config, money_config, reservations_config, invitations_config). Permission gate: context.manage. Deep merge en nested configs. Retorna context_settings_summary(...) para refresh inmediato.';
