-- R.0A.1 MIG 1 — Forward-sync trigger: profiles INSERT → actors person row.
-- Scope: solo INSERT (existence forward-sync). NO UPDATE.
-- display_name drift aceptado durante todo R.0; lecturas usan
-- COALESCE(profile.display_name, profile.username, actors.display_name) cuando aplique.
--
-- SECURITY DEFINER: el trigger debe poder insertar en actors aunque el caller no tenga
-- permiso directo (signup path corre como anon/authenticated role).
-- ON CONFLICT DO NOTHING: defense-in-depth para no romper si por alguna razón
-- ya existe un actor con el mismo id (ej. backfill manual + insert simultáneo).

CREATE OR REPLACE FUNCTION public._sync_actor_from_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.actors (id, actor_kind, display_name, metadata)
  VALUES (
    NEW.id,
    'person',
    COALESCE(NULLIF(NEW.display_name, ''), NULLIF(NEW.username, ''), '(unnamed person)'),
    jsonb_build_object('source', 'r0a1_forward_sync_profile')
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_actor_from_profile
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public._sync_actor_from_profile();

COMMENT ON FUNCTION public._sync_actor_from_profile() IS
  'R.0A.1. Forward-sync: cuando se crea un profile, garantiza que exista el actor row correspondiente (kind=person, shared UUID). INSERT-only — display_name drift es aceptable durante R.0.';
