-- 20260526110000 — Profile self-service RPCs (Foundation onboarding nudge).
--
-- Adds my_profile() + update_my_profile(...) so iOS can read/upsert the
-- caller's profile through canonical RPCs. RLS untouched.

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
  RAISE EXCEPTION 'username already taken' USING errcode = '23505';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_my_profile(text, text, text, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.update_my_profile(text, text, text, text) TO authenticated;

COMMENT ON FUNCTION public.update_my_profile(text, text, text, text) IS
  'Foundation profile slice (mig 20260526110000): upsert the caller''s profile (display_name, username, avatar_url, bio). Trims + lowercases username; validates non-empty display_name and unique username. Raises ''must be authenticated'' | ''display_name required'' | ''username already taken''. Email/phone NOT editable here (live on auth.users).';
