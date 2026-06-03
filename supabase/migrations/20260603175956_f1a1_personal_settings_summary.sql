-- F.1A-1 — personal_settings_summary()
-- Devuelve la configuración personal del actor autenticado: profile, notifications,
-- privacy, calendar, contexts, integrations, available_actions.
-- Sin tablas nuevas — todo persistido en `person_profiles.metadata`.
-- Frontend NO calcula permisos: available_actions viene siempre del backend.

CREATE OR REPLACE FUNCTION public.personal_settings_summary()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor uuid := public.current_actor_id();
  v_profile public.person_profiles%rowtype;
  v_meta jsonb;
  v_notifications jsonb;
  v_privacy jsonb;
  v_calendar jsonb;
  v_contexts jsonb;
  v_integrations jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '28000'; END IF;

  SELECT * INTO v_profile FROM public.person_profiles WHERE actor_id = v_actor;
  IF v_profile.actor_id IS NULL THEN
    RAISE EXCEPTION 'profile not found' USING errcode = 'P0002';
  END IF;

  v_meta := COALESCE(v_profile.metadata, '{}'::jsonb);

  -- Notifications: 7 categorías, default todas activas en push.
  -- Cada slot es una jsonb con {push, email} bool.
  v_notifications := jsonb_build_object(
    'invitations',   COALESCE(v_meta->'notifications'->'invitations',   '{"push": true, "email": true}'::jsonb),
    'decisions',     COALESCE(v_meta->'notifications'->'decisions',     '{"push": true, "email": true}'::jsonb),
    'reservations',  COALESCE(v_meta->'notifications'->'reservations',  '{"push": true, "email": true}'::jsonb),
    'events',        COALESCE(v_meta->'notifications'->'events',        '{"push": true, "email": true}'::jsonb),
    'obligations',   COALESCE(v_meta->'notifications'->'obligations',   '{"push": true, "email": true}'::jsonb),
    'money',         COALESCE(v_meta->'notifications'->'money',         '{"push": true, "email": true}'::jsonb),
    'rules',         COALESCE(v_meta->'notifications'->'rules',         '{"push": true, "email": false}'::jsonb)
  );

  v_privacy := jsonb_build_object(
    'discoverable_by',     COALESCE(v_meta->'privacy'->>'discoverable_by',     'members_in_common'),
    'who_can_invite_me',   COALESCE(v_meta->'privacy'->>'who_can_invite_me',   'members_in_common'),
    'profile_visibility',  COALESCE(v_meta->'privacy'->>'profile_visibility',  'members_in_common')
  );

  v_calendar := jsonb_build_object(
    'time_zone',       COALESCE(v_meta->'calendar'->>'time_zone',       'America/Mexico_City'),
    'first_day_of_week', COALESCE(v_meta->'calendar'->>'first_day_of_week', 'monday')
  );

  v_contexts := jsonb_build_object(
    'default_context_actor_id', v_meta->'contexts'->>'default_context_actor_id',
    'last_context_actor_id',    v_meta->'contexts'->>'last_context_actor_id'
  );

  v_integrations := jsonb_build_object(
    'google_calendar', COALESCE(v_meta->'integrations'->'google_calendar', '{"connected": false}'::jsonb),
    'apple_calendar',  COALESCE(v_meta->'integrations'->'apple_calendar',  '{"connected": false}'::jsonb),
    'wise',            COALESCE(v_meta->'integrations'->'wise',            '{"connected": false}'::jsonb),
    'whatsapp',        COALESCE(v_meta->'integrations'->'whatsapp',        '{"connected": false}'::jsonb)
  );

  RETURN jsonb_build_object(
    'actor_id', v_actor,
    'profile', jsonb_build_object(
      'full_name',       v_profile.full_name,
      'preferred_name',  v_profile.preferred_name,
      'phone',           v_profile.phone,
      'email',           v_profile.email,
      'avatar_url',      v_profile.avatar_url
    ),
    'notifications', v_notifications,
    'privacy',       v_privacy,
    'calendar',      v_calendar,
    'contexts',      v_contexts,
    'integrations',  v_integrations,
    -- Personal settings: el actor siempre puede editar lo suyo.
    'available_actions', jsonb_build_array(
      'edit_profile',
      'edit_notifications',
      'edit_privacy',
      'edit_calendar',
      'edit_contexts',
      'edit_integrations'
    )
  );
END $$;

REVOKE EXECUTE ON FUNCTION public.personal_settings_summary() FROM anon;
