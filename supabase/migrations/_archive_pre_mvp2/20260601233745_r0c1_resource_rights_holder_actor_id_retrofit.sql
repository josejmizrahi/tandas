-- R.0C.1 — Rights Actor Holder Retrofit (ATOMIC)
--
-- Doctrina:
--   - Agregar holder_actor_id como nuevo FK a actors(id).
--   - Backfill desde holder_membership_id vía group_memberships.user_id.
--   - holder_membership_id queda como columna compat/deprecated durante R.0
--     (lecturas legacy siguen usándola; drop diferido a R.1+).
--   - NO whitelist de right_kind todavía (R.0C.2).
--   - NO backfill OWN desde resource_owners todavía (R.0C.2).
--   - NO RPCs grant_right/revoke_right/actor_has_right todavía (R.0C.2).
--   - NO sync trigger canonical_owner_actor_id ← OWN todavía (R.0C.2).
--
-- Out of scope: percent, scope, starts_at, ends_at, primary key change.

-- ============================================================
-- STEP 1: ADD COLUMN holder_actor_id FK actors
-- ============================================================
ALTER TABLE public.resource_rights
  ADD COLUMN holder_actor_id uuid REFERENCES public.actors(id);

CREATE INDEX idx_resource_rights_holder_actor_id
  ON public.resource_rights(holder_actor_id)
 WHERE holder_actor_id IS NOT NULL;

COMMENT ON COLUMN public.resource_rights.holder_actor_id IS
  'R.0C.1 actor-aware holder. Reemplaza semánticamente a holder_membership_id (que queda deprecated durante R.0). Backfilleado desde group_memberships.user_id = actors.id (person actor). NULL permitido (right sin holder específico, ej. público o sistémico).';
COMMENT ON COLUMN public.resource_rights.holder_membership_id IS
  'R.0C.1 deprecated/compat. holder_actor_id es la nueva fuente. Drop diferido a R.1/R.2.';

-- ============================================================
-- STEP 2: Backfill holder_actor_id desde holder_membership_id
-- ============================================================
-- group_memberships.user_id = auth.users.id = actors.id (person) por D2 R.0A + R.0A.1 forward-sync.
-- Idempotente: solo afecta filas con holder_actor_id IS NULL.
UPDATE public.resource_rights AS rr
   SET holder_actor_id = gm.user_id
  FROM public.group_memberships AS gm
 WHERE rr.holder_membership_id IS NOT NULL
   AND rr.holder_actor_id IS NULL
   AND gm.id = rr.holder_membership_id;

-- ============================================================
-- STEP 3: Defensive BEFORE INSERT/UPDATE trigger sobre resource_rights
-- ============================================================
-- Self-healing: si caller no setea holder_actor_id y sí holder_membership_id,
-- deriva holder_actor_id desde la membership. Permite que código legacy siga
-- escribiendo solo membership_id y obtenga automáticamente el holder actor.

CREATE OR REPLACE FUNCTION public._resource_rights_derive_holder_actor_id()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  IF NEW.holder_actor_id IS NULL AND NEW.holder_membership_id IS NOT NULL THEN
    SELECT user_id INTO v_user_id
      FROM public.group_memberships
     WHERE id = NEW.holder_membership_id;
    IF v_user_id IS NOT NULL THEN
      NEW.holder_actor_id := v_user_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_resource_rights_derive_holder_actor_id
  BEFORE INSERT OR UPDATE OF holder_membership_id ON public.resource_rights
  FOR EACH ROW
  EXECUTE FUNCTION public._resource_rights_derive_holder_actor_id();

COMMENT ON FUNCTION public._resource_rights_derive_holder_actor_id() IS
  'R.0C.1 defensive derivation. Si caller no setea holder_actor_id y sí holder_membership_id, deriva holder_actor_id desde group_memberships.user_id. Self-healing para legacy writers.';

-- ============================================================
-- STEP 4: Refresh compat view group_resource_rights (incluye nueva columna)
-- ============================================================
CREATE OR REPLACE VIEW public.group_resource_rights AS
  SELECT * FROM public.resource_rights;

COMMENT ON VIEW public.group_resource_rights IS
  'R.0B.1 compat view + R.0C.1 holder_actor_id exposure. Redirige a public.resource_rights vía INSTEAD OF triggers.';

-- ============================================================
-- STEP 5: Update INSTEAD OF triggers para forward holder_actor_id
-- ============================================================
CREATE OR REPLACE FUNCTION public._compat_group_resource_rights_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.resource_rights (
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
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE public.resource_rights SET
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
