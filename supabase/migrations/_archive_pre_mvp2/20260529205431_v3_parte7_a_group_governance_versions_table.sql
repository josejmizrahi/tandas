-- V3 PARTE 7a — group_governance_versions append-only atom
--
-- Estado previo: groups.decision_rules es jsonb mutable; cada call a
-- set_decision_rules sobrescribe la jsonb sin historia. Si después una
-- disputa cuestiona "¿bajo qué reglas votamos esa decisión?", no se puede
-- reconstruir.
--
-- Esta tabla guarda cada snapshot. Append-only: la única columna mutable
-- es `effective_until` (la setea el siguiente set_decision_rules para
-- cerrar la versión previa). Resto bloqueado por _group_governance_versions_partial_guard.
--
-- Lookup natural: "rules vigentes en T" = SELECT WHERE effective_from <= T
-- AND (effective_until IS NULL OR effective_until > T).
--
-- source_decision_id: NULL para set_decision_rules directos (admin path);
-- llevará el decision_id cuando el outcome handler de finalize_vote
-- decida cambiar las reglas (PARTE 4 governance_change handler, futuro).

CREATE TABLE IF NOT EXISTS public.group_governance_versions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id            uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  snapshot            jsonb NOT NULL,
  effective_from      timestamptz NOT NULL DEFAULT now(),
  effective_until     timestamptz,
  set_by              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  source_decision_id  uuid REFERENCES public.group_decisions(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- Lookup hot path: latest active version per group
CREATE UNIQUE INDEX IF NOT EXISTS one_active_governance_version_per_group
  ON public.group_governance_versions(group_id)
  WHERE effective_until IS NULL;

CREATE INDEX IF NOT EXISTS group_governance_versions_by_group_time
  ON public.group_governance_versions(group_id, effective_from DESC);

ALTER TABLE public.group_governance_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS group_governance_versions_select_members ON public.group_governance_versions;
CREATE POLICY group_governance_versions_select_members
  ON public.group_governance_versions
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.group_memberships gm
       WHERE gm.group_id = group_governance_versions.group_id
         AND gm.user_id = auth.uid()
         AND gm.status = 'active'
    )
  );

-- Partial atom guard: only effective_until is mutable.
CREATE OR REPLACE FUNCTION public._group_governance_versions_partial_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.id                 IS DISTINCT FROM OLD.id                 THEN RAISE EXCEPTION 'immutable: group_governance_versions.id'                 USING errcode = '23514'; END IF;
  IF NEW.group_id           IS DISTINCT FROM OLD.group_id           THEN RAISE EXCEPTION 'immutable: group_governance_versions.group_id'           USING errcode = '23514'; END IF;
  IF NEW.snapshot           IS DISTINCT FROM OLD.snapshot           THEN RAISE EXCEPTION 'immutable: group_governance_versions.snapshot'           USING errcode = '23514'; END IF;
  IF NEW.effective_from     IS DISTINCT FROM OLD.effective_from     THEN RAISE EXCEPTION 'immutable: group_governance_versions.effective_from'     USING errcode = '23514'; END IF;
  IF NEW.set_by             IS DISTINCT FROM OLD.set_by             THEN RAISE EXCEPTION 'immutable: group_governance_versions.set_by'             USING errcode = '23514'; END IF;
  IF NEW.source_decision_id IS DISTINCT FROM OLD.source_decision_id THEN RAISE EXCEPTION 'immutable: group_governance_versions.source_decision_id' USING errcode = '23514'; END IF;
  IF NEW.created_at         IS DISTINCT FROM OLD.created_at         THEN RAISE EXCEPTION 'immutable: group_governance_versions.created_at'         USING errcode = '23514'; END IF;
  -- effective_until mutable
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS group_governance_versions_partial_guard ON public.group_governance_versions;
CREATE TRIGGER group_governance_versions_partial_guard
  BEFORE UPDATE ON public.group_governance_versions
  FOR EACH ROW EXECUTE FUNCTION public._group_governance_versions_partial_guard();

DROP TRIGGER IF EXISTS group_governance_versions_no_delete ON public.group_governance_versions;
CREATE TRIGGER group_governance_versions_no_delete
  BEFORE DELETE ON public.group_governance_versions
  FOR EACH ROW EXECUTE FUNCTION public.atom_no_delete_guard();

COMMENT ON TABLE public.group_governance_versions IS
  'V3 PARTE 7a: append-only audit trail for groups.decision_rules snapshots. effective_until is the only mutable column (closed by next set_decision_rules). Lookup vigente: WHERE effective_until IS NULL.';
