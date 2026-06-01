-- R.0C.2a — Universal Resource Rights Table + Backfill + Canonical Sync (ATOMIC)
--
-- Founder doctrine — Opción C:
--   - resource_rights legacy es subtype polimórfico (resource_type='right'). NO salvageable como universal.
--   - Rename legacy → resource_right_subtype, conservar para compat.
--   - Crear NUEVA resource_rights universal con shape correcta R.0.
--   - Backfill desde resource_owners (no destructivo).
--   - Sync canonical_owner_actor_id ← OWN-mayor-percent.
--
-- Ajustes founder:
--   1) percent CHECK [0..100] o NULL
--   2) Unique partial index handles NULL holder_actor_id via COALESCE
--   3) external_party NULL holder_actor_id + metadata.external_party_id
--   4) sync ignora revoked/expired/ends_at < now()
--   5) sin OWN activo → NO clear canonical (legacy cache permanece)

-- ============================================================
-- STEP 1: RENAME legacy table + renombrar índices/constraints conflictivos
-- ============================================================
ALTER TABLE public.resource_rights RENAME TO resource_right_subtype;
ALTER INDEX public.idx_resource_rights_holder_actor_id RENAME TO idx_resource_right_subtype_holder_actor_id;
ALTER TABLE public.resource_right_subtype
  RENAME CONSTRAINT resource_rights_holder_actor_id_fkey TO resource_right_subtype_holder_actor_id_fkey;

COMMENT ON TABLE public.resource_right_subtype IS
  'R.0C.2a legacy subtype polimórfico de resources con resource_type=''right''. Conservado para compat. La nueva universal resource_rights vive aparte y es la autoridad del sistema de derechos R.0.';

-- ============================================================
-- STEP 2: Repoint compat view triggers a la tabla renombrada
-- ============================================================
CREATE OR REPLACE FUNCTION public._compat_group_resource_rights_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  INSERT INTO public.resource_right_subtype (
    resource_id, right_kind, holder_membership_id,
    granted_at, expires_at, expired_at, revoked_at,
    transferable, conditions, holder_actor_id
  ) VALUES (
    NEW.resource_id, NEW.right_kind, NEW.holder_membership_id,
    COALESCE(NEW.granted_at, now()), NEW.expires_at, NEW.expired_at, NEW.revoked_at,
    COALESCE(NEW.transferable, false), NEW.conditions, NEW.holder_actor_id
  )
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resource_rights_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  UPDATE public.resource_right_subtype SET
    resource_id = NEW.resource_id,
    right_kind = NEW.right_kind,
    holder_membership_id = NEW.holder_membership_id,
    granted_at = NEW.granted_at,
    expires_at = NEW.expires_at,
    expired_at = NEW.expired_at,
    revoked_at = NEW.revoked_at,
    transferable = NEW.transferable,
    conditions = NEW.conditions,
    holder_actor_id = NEW.holder_actor_id
  WHERE resource_id = OLD.resource_id AND right_kind = OLD.right_kind
  RETURNING * INTO NEW;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._compat_group_resource_rights_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  DELETE FROM public.resource_right_subtype
   WHERE resource_id = OLD.resource_id AND right_kind = OLD.right_kind;
  RETURN OLD;
END;
$$;

CREATE OR REPLACE VIEW public.group_resource_rights AS
  SELECT * FROM public.resource_right_subtype;

COMMENT ON VIEW public.group_resource_rights IS
  'R.0B.1 compat view repointed en R.0C.2a a resource_right_subtype. NO confundir con la nueva universal resource_rights.';

-- ============================================================
-- STEP 3: CREATE TABLE resource_rights (NUEVA universal)
-- ============================================================
CREATE TABLE public.resource_rights (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_id        uuid NOT NULL REFERENCES public.resources(id) ON DELETE CASCADE,
  holder_actor_id    uuid REFERENCES public.actors(id),
  right_kind         text NOT NULL CHECK (right_kind IN (
    'OWN','USE','MANAGE','SELL','TRANSFER','GOVERN','BENEFICIARY',
    'PLEDGE','LIEN','LEASE','COLLECT_INCOME','PAY_EXPENSES',
    'AUDIT','APPROVE','VIEW'
  )),
  percent            numeric CHECK (percent IS NULL OR (percent >= 0 AND percent <= 100)),
  scope              text,
  starts_at          timestamptz,
  ends_at            timestamptz,
  granted_at         timestamptz NOT NULL DEFAULT now(),
  revoked_at         timestamptz,
  expired_at         timestamptz,
  source_decision_id uuid REFERENCES public.group_decisions(id),
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.resource_rights IS
  'R.0C.2a universal rights table. Autoridad de ownership y permisos sobre recursos según R.0 doctrine. Para subtype semantics (rights-as-resources) usar resource_right_subtype.';
COMMENT ON COLUMN public.resource_rights.holder_actor_id IS
  'NULL = right sin holder específico (sistémico, anónimo, o external party con metadata.external_party_id).';
COMMENT ON COLUMN public.resource_rights.percent IS
  'Porcentaje 0..100. Principalmente OWN parcial. NULL = no aplicable (USE, MANAGE, etc).';

-- ============================================================
-- STEP 4: Indexes
-- ============================================================
CREATE UNIQUE INDEX uq_resource_rights_active
  ON public.resource_rights (
    resource_id,
    COALESCE(holder_actor_id, '00000000-0000-0000-0000-000000000000'::uuid),
    right_kind
  )
  WHERE revoked_at IS NULL AND expired_at IS NULL;

CREATE INDEX idx_resource_rights_resource_id ON public.resource_rights(resource_id);
CREATE INDEX idx_resource_rights_holder_actor_id ON public.resource_rights(holder_actor_id)
  WHERE holder_actor_id IS NOT NULL;
CREATE INDEX idx_resource_rights_right_kind ON public.resource_rights(right_kind);
CREATE INDEX idx_resource_rights_active_own
  ON public.resource_rights(resource_id, holder_actor_id, percent DESC)
  WHERE right_kind = 'OWN' AND revoked_at IS NULL AND expired_at IS NULL;

-- ============================================================
-- STEP 5: RLS
-- ============================================================
ALTER TABLE public.resource_rights ENABLE ROW LEVEL SECURITY;
CREATE POLICY resource_rights_select_authenticated
  ON public.resource_rights FOR SELECT TO authenticated USING (true);

-- ============================================================
-- STEP 6: Touch updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION public._resource_rights_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;

CREATE TRIGGER trg_resource_rights_touch_updated_at
  BEFORE UPDATE ON public.resource_rights
  FOR EACH ROW EXECUTE FUNCTION public._resource_rights_touch_updated_at();

-- ============================================================
-- STEP 7: Backfill desde resource_owners → resource_rights OWN
-- ============================================================
INSERT INTO public.resource_rights (
  resource_id, holder_actor_id, right_kind, percent,
  starts_at, ends_at, source_decision_id, metadata
)
SELECT
  ro.resource_id,
  CASE
    WHEN ro.owner_kind = 'member' AND ro.membership_id IS NOT NULL THEN
      (SELECT user_id FROM public.group_memberships WHERE id = ro.membership_id)
    WHEN ro.owner_kind = 'group' THEN
      (SELECT group_id FROM public.resources WHERE id = ro.resource_id)
    ELSE NULL
  END,
  'OWN',
  ro.ownership_pct,
  ro.starts_at,
  ro.ends_at,
  ro.source_decision_id,
  jsonb_build_object(
    'backfill_source', 'resource_owners',
    'backfill_owner_kind', ro.owner_kind,
    'backfill_ownership_role', ro.ownership_role,
    'external_party_id', ro.external_party_id,
    'legacy_owner_id', ro.id
  ) || COALESCE(ro.metadata, '{}'::jsonb)
  FROM public.resource_owners ro
 WHERE NOT EXISTS (
   SELECT 1 FROM public.resource_rights rr
   WHERE rr.resource_id = ro.resource_id
     AND rr.right_kind = 'OWN'
     AND rr.metadata->>'legacy_owner_id' = ro.id::text
 );

-- ============================================================
-- STEP 8: Canonical owner sync trigger (founder #4 + #5)
-- ============================================================
CREATE OR REPLACE FUNCTION public._resource_rights_sync_canonical_owner()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_resource_id uuid;
  v_new_owner   uuid;
BEGIN
  v_resource_id := COALESCE(NEW.resource_id, OLD.resource_id);

  IF (TG_OP = 'INSERT' AND NEW.right_kind = 'OWN')
     OR (TG_OP = 'UPDATE' AND (NEW.right_kind = 'OWN' OR OLD.right_kind = 'OWN'))
     OR (TG_OP = 'DELETE' AND OLD.right_kind = 'OWN') THEN

    SELECT holder_actor_id INTO v_new_owner
      FROM public.resource_rights
     WHERE resource_id = v_resource_id
       AND right_kind = 'OWN'
       AND revoked_at IS NULL
       AND expired_at IS NULL
       AND (ends_at IS NULL OR ends_at > now())
       AND holder_actor_id IS NOT NULL
     ORDER BY COALESCE(percent, 0) DESC, granted_at DESC
     LIMIT 1;

    -- Founder #5: NO clear si no hay OWN activo (legacy cache permanece)
    IF v_new_owner IS NOT NULL THEN
      UPDATE public.resources
         SET canonical_owner_actor_id = v_new_owner
       WHERE id = v_resource_id
         AND canonical_owner_actor_id IS DISTINCT FROM v_new_owner;
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_resource_rights_sync_canonical_owner
  AFTER INSERT OR UPDATE OR DELETE ON public.resource_rights
  FOR EACH ROW
  EXECUTE FUNCTION public._resource_rights_sync_canonical_owner();

COMMENT ON FUNCTION public._resource_rights_sync_canonical_owner() IS
  'R.0C.2a sync: canonical_owner_actor_id ← OWN holder con mayor percent. Ignora revoked/expired/ends_at<now/holder NULL. NO clear si no hay OWN activo (founder #5).';

-- ============================================================
-- STEP 9: One-shot backfill canonical_owner_actor_id desde nuevos OWN rights
-- ============================================================
WITH owners_by_resource AS (
  SELECT DISTINCT ON (resource_id)
         resource_id, holder_actor_id
    FROM public.resource_rights
   WHERE right_kind = 'OWN'
     AND revoked_at IS NULL
     AND expired_at IS NULL
     AND (ends_at IS NULL OR ends_at > now())
     AND holder_actor_id IS NOT NULL
   ORDER BY resource_id, COALESCE(percent, 0) DESC, granted_at DESC
)
UPDATE public.resources r
   SET canonical_owner_actor_id = o.holder_actor_id
  FROM owners_by_resource o
 WHERE r.id = o.resource_id
   AND (r.canonical_owner_actor_id IS DISTINCT FROM o.holder_actor_id);
