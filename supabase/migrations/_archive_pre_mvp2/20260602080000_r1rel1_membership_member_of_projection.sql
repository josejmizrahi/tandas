-- R.1-REL.1 — Membership → member_of projection
--
-- Audit PR #131 gap 6: actor_relationships tenía 0 rows y las membresías no se
-- proyectaban al grafo. La doctrina pide que `member_of` refleje la participación
-- operativa real.
--
-- Proyección:
--   group_memberships activa (user_id NOT NULL) →
--     actor_relationships(subject=user_id, type=member_of, object_actor=group_id)
--   Al pasar a removed/left/banned/suspended → ends_at = now()
--   (paused NO cierra la relación — es participación temporalmente suspendida
--    pero la membresía sigue viva)
--
-- Idempotente: trigger + backfill usan NOT EXISTS / UPDATE condicional.

-- ============================================================
-- 1. Trigger function de proyección
-- ============================================================
CREATE OR REPLACE FUNCTION public._sync_member_of_relationship()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- Solo memberships de personas reales (placeholders tienen user_id NULL)
  IF NEW.user_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'active' THEN
    -- Abrir (o reabrir) la relación member_of si no hay una activa
    INSERT INTO public.actor_relationships
      (subject_actor_id, relationship_type, object_actor_id, starts_at, metadata)
    SELECT NEW.user_id, 'member_of', NEW.group_id, COALESCE(NEW.joined_at, now()),
           jsonb_build_object(
             'source', 'r1rel_membership_projection',
             'membership_id', NEW.id,
             'membership_type', NEW.membership_type)
     WHERE NOT EXISTS (
       SELECT 1 FROM public.actor_relationships ar
       WHERE ar.subject_actor_id = NEW.user_id
         AND ar.object_actor_id = NEW.group_id
         AND ar.relationship_type = 'member_of'
         AND ar.ends_at IS NULL
     );

  ELSIF NEW.status IN ('removed', 'left', 'banned', 'suspended') THEN
    -- Cerrar la relación activa
    UPDATE public.actor_relationships ar
       SET ends_at = now(),
           metadata = ar.metadata || jsonb_build_object(
             'end_source', 'r1rel_membership_projection',
             'end_status', NEW.status)
     WHERE ar.subject_actor_id = NEW.user_id
       AND ar.object_actor_id = NEW.group_id
       AND ar.relationship_type = 'member_of'
       AND ar.ends_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._sync_member_of_relationship() IS
  'R.1-REL.1: proyecta group_memberships → actor_relationships.member_of. Active abre la relación; removed/left/banned/suspended la cierra (ends_at).';

DROP TRIGGER IF EXISTS trg_group_memberships_sync_member_of ON public.group_memberships;
CREATE TRIGGER trg_group_memberships_sync_member_of
  AFTER INSERT OR UPDATE OF status ON public.group_memberships
  FOR EACH ROW EXECUTE FUNCTION public._sync_member_of_relationship();

-- ============================================================
-- 2. Backfill: memberships activas existentes → member_of
-- ============================================================
INSERT INTO public.actor_relationships
  (subject_actor_id, relationship_type, object_actor_id, starts_at, metadata)
SELECT gm.user_id, 'member_of', gm.group_id, COALESCE(gm.joined_at, gm.created_at),
       jsonb_build_object(
         'source', 'r1rel_membership_projection_backfill',
         'membership_id', gm.id,
         'membership_type', gm.membership_type)
  FROM public.group_memberships gm
 WHERE gm.status = 'active'
   AND gm.user_id IS NOT NULL
   -- el subject y el object deben existir como actors (forward-sync R.0A.1 lo garantiza,
   -- pero defendemos contra huérfanos)
   AND EXISTS (SELECT 1 FROM public.actors a WHERE a.id = gm.user_id)
   AND EXISTS (SELECT 1 FROM public.actors a WHERE a.id = gm.group_id)
   AND NOT EXISTS (
     SELECT 1 FROM public.actor_relationships ar
     WHERE ar.subject_actor_id = gm.user_id
       AND ar.object_actor_id = gm.group_id
       AND ar.relationship_type = 'member_of'
       AND ar.ends_at IS NULL
   );

-- Verificación inline
DO $$
DECLARE
  v_missing integer;
BEGIN
  SELECT count(*) INTO v_missing
    FROM public.group_memberships gm
   WHERE gm.status = 'active'
     AND gm.user_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.actors a WHERE a.id = gm.user_id)
     AND EXISTS (SELECT 1 FROM public.actors a WHERE a.id = gm.group_id)
     AND NOT EXISTS (
       SELECT 1 FROM public.actor_relationships ar
       WHERE ar.subject_actor_id = gm.user_id
         AND ar.object_actor_id = gm.group_id
         AND ar.relationship_type = 'member_of'
         AND ar.ends_at IS NULL
     );
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'r1rel1 backfill incomplete: % active memberships without member_of', v_missing;
  END IF;
  RAISE NOTICE 'r1rel1 backfill complete: todas las memberships activas tienen member_of';
END $$;
