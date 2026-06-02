-- R.0A.1 MIG 2 — Forward-sync trigger: groups INSERT → actors group row.
-- Mismas reglas que MIG 1: solo INSERT, SECDEF, ON CONFLICT DO NOTHING.

CREATE OR REPLACE FUNCTION public._sync_actor_from_group()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.actors (id, actor_kind, display_name, metadata)
  VALUES (
    NEW.id,
    'group',
    COALESCE(NULLIF(NEW.name, ''), '(unnamed group)'),
    jsonb_build_object('source', 'r0a1_forward_sync_group')
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_actor_from_group
  AFTER INSERT ON public.groups
  FOR EACH ROW
  EXECUTE FUNCTION public._sync_actor_from_group();

COMMENT ON FUNCTION public._sync_actor_from_group() IS
  'R.0A.1. Forward-sync: cuando se crea un group, garantiza que exista el actor row correspondiente (kind=group, shared UUID). INSERT-only — display_name drift es aceptable durante R.0.';
