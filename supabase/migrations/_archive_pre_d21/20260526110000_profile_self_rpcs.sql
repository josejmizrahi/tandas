-- 20260526110000 — Profile self-service RPCs (Foundation onboarding nudge).
--
-- Founder ask 2026-05-26: profiles.display_name puede ser null/empty
-- después del signup (Apple no envía nombre, OTP nunca lo pide).
-- Necesitamos que el usuario complete su nombre antes de aparecer en
-- Members, Money, Invites, etc. iOS no escribe profiles directo; toda
-- mutación pasa por RPC (doctrine: backend es fuente de verdad).
--
-- Esta migración añade DOS RPCs canónicas:
--
--   public.my_profile() returns public.profiles
--     ─ devuelve el profile del caller. Si no existe, lo crea mínimo
--       (id = auth.uid(), display_name=null) y lo devuelve. Garantiza
--       que el primer signed-in fetch del cliente siempre resuelve.
--
--   public.update_my_profile(p_display_name, p_username, p_avatar_url, p_bio)
--     returns public.profiles
--     ─ upsert del profile propio. Valida display_name no vacío,
--       username único (lowercase), todo trimmed. Errores canónicos:
--         'must be authenticated'
--         'display_name required'
--         'username already taken'
--
-- Email/phone NO se editan aquí (eso vive en auth.users + auth flows).
-- Avatar upload NO se maneja aquí (Storage no entra en este slice;
-- p_avatar_url acepta cualquier string que el cliente quiera persistir
-- como referencia, sin validación de Storage).
--
-- RLS sin tocar — sigue protegiendo writes directos a la tabla. Las
-- RPCs son SECURITY DEFINER y validan auth.uid() antes de mutar.

-- ===========================================================================
-- 1. RPC: my_profile
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.my_profile()
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_profile public.profiles;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;

  IF v_profile.id IS NULL THEN
    -- Bootstrap an empty profile so the first signed-in fetch always
    -- resolves. display_name stays NULL so the onboarding nudge fires
    -- and the user fills it in before they appear in Members/Money UI.
    INSERT INTO public.profiles (id, display_name, username, avatar_url, bio, created_at, updated_at)
    VALUES (v_uid, NULL, NULL, NULL, NULL, now(), now())
    ON CONFLICT (id) DO NOTHING;

    SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;
  END IF;

  RETURN v_profile;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.my_profile() FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.my_profile() TO authenticated;

COMMENT ON FUNCTION public.my_profile() IS
  'Foundation profile slice (mig 20260526110000): returns the caller''s public.profiles row. Creates an empty one (display_name NULL) on first call so the signed-in onboarding nudge can fire deterministically.';

-- ===========================================================================
-- 2. RPC: update_my_profile
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.update_my_profile(
  p_display_name text,
  p_username     text DEFAULT NULL,
  p_avatar_url   text DEFAULT NULL,
  p_bio          text DEFAULT NULL
)
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid           uuid := auth.uid();
  v_display_name  text;
  v_username      text;
  v_avatar_url    text;
  v_bio           text;
  v_profile       public.profiles;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  v_display_name := NULLIF(btrim(p_display_name), '');
  IF v_display_name IS NULL THEN
    RAISE EXCEPTION 'display_name required' USING errcode = '22023';
  END IF;

  v_username := NULLIF(lower(btrim(coalesce(p_username, ''))), '');
  IF v_username IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.profiles
       WHERE username = v_username
         AND id <> v_uid
    ) THEN
      RAISE EXCEPTION 'username already taken' USING errcode = '23505';
    END IF;
  END IF;

  v_avatar_url := NULLIF(btrim(coalesce(p_avatar_url, '')), '');
  v_bio        := NULLIF(btrim(coalesce(p_bio, '')), '');

  -- Upsert preserves created_at when the row already exists (we never
  -- write it in DO UPDATE) and refreshes updated_at on every call.
  INSERT INTO public.profiles (
    id, display_name, username, avatar_url, bio, created_at, updated_at
  ) VALUES (
    v_uid, v_display_name, v_username, v_avatar_url, v_bio, now(), now()
  )
  ON CONFLICT (id) DO UPDATE
     SET display_name = EXCLUDED.display_name,
         username     = EXCLUDED.username,
         avatar_url   = EXCLUDED.avatar_url,
         bio          = EXCLUDED.bio,
         updated_at   = now()
  RETURNING * INTO v_profile;

  RETURN v_profile;

EXCEPTION WHEN unique_violation THEN
  -- Race: another concurrent update grabbed the same username between
  -- the EXISTS check and the upsert. Surface the canonical error.
  RAISE EXCEPTION 'username already taken' USING errcode = '23505';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_my_profile(text, text, text, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.update_my_profile(text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.update_my_profile(text, text, text, text) IS
  'Foundation profile slice (mig 20260526110000): upsert the caller''s profile (display_name, username, avatar_url, bio). Trims + lowercases username; validates non-empty display_name and unique username. Raises ''must be authenticated'' | ''display_name required'' | ''username already taken''. Email/phone NOT editable here (live on auth.users).';
