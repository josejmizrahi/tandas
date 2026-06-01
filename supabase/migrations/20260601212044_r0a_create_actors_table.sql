-- R.0A MIG 1 — Actor Registry parent table.
-- Doctrina: doctrine_r0_actor_resource_rights.md
-- Plan: Plans/Active/R0_ActorResourceRights.md §4 R.0A
--
-- D1: actors es tabla parent real (no polimorfismo plano).
-- D2: UUIDs compartidos con profiles/groups (sin FK formal — backfill en MIG 2).
-- D3: actor_kind whitelist = person | group | legal_entity.

CREATE TABLE public.actors (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_kind    text NOT NULL CHECK (actor_kind IN ('person','group','legal_entity')),
  display_name  text NOT NULL,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_actors_actor_kind ON public.actors(actor_kind);
CREATE INDEX idx_actors_display_name_lower ON public.actors(lower(display_name));

-- Touch updated_at on UPDATE
CREATE OR REPLACE FUNCTION public._actors_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_actors_touch_updated_at
  BEFORE UPDATE ON public.actors
  FOR EACH ROW
  EXECUTE FUNCTION public._actors_touch_updated_at();

-- RLS: read open to authenticated; writes only via SECDEF RPCs (deny-by-default).
ALTER TABLE public.actors ENABLE ROW LEVEL SECURITY;

CREATE POLICY actors_select_authenticated
  ON public.actors
  FOR SELECT
  TO authenticated
  USING (true);

COMMENT ON TABLE public.actors IS
  'R.0A. Parent table for all actors (person|group|legal_entity). UUIDs shared 1:1 with profiles/groups/legal_entities. Forward-sync trigger from profiles/groups deferred to R.0B (strict R.0A is additive-only).';
COMMENT ON COLUMN public.actors.actor_kind IS
  'Whitelist: person | group | legal_entity. Enforced via CHECK constraint.';
