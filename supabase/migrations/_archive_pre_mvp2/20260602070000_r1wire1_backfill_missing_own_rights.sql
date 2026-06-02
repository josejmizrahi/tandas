-- R.1-WIRE.1 — Backfill missing OWN rights
--
-- Audit PR #131 R5: 33/110 resources tenían canonical_owner_actor_id sin ningún
-- OWN right activo que lo respalde (poblados por el trigger defensivo R.0B.2 a
-- partir de group_id, no por rights). resource_rights debe ser la fuente formal
-- de relevancia — todo resource con canonical owner debe tener su OWN.
--
-- Idempotente: NOT EXISTS hace el re-run no-op. Incluye archived (la propiedad
-- histórica sigue siendo del owner). Resources sin canonical_owner_actor_id
-- (system/unowned) quedan explícitamente fuera.

INSERT INTO public.resource_rights (resource_id, holder_actor_id, right_kind, percent, metadata)
SELECT r.id,
       r.canonical_owner_actor_id,
       'OWN',
       100,
       jsonb_build_object('backfill_source', 'r1_wire_missing_own')
  FROM public.resources r
 WHERE r.canonical_owner_actor_id IS NOT NULL
   AND NOT EXISTS (
     SELECT 1 FROM public.resource_rights rr
     WHERE rr.resource_id = r.id
       AND rr.right_kind = 'OWN'
       AND rr.revoked_at IS NULL
       AND rr.expired_at IS NULL
       AND (rr.starts_at IS NULL OR rr.starts_at <= now())
       AND (rr.ends_at IS NULL OR rr.ends_at > now())
   );

-- Verificación inline: después del backfill no debe quedar ningún resource con
-- canonical owner sin OWN activo.
DO $$
DECLARE
  v_missing integer;
BEGIN
  SELECT count(*) INTO v_missing
    FROM public.resources r
   WHERE r.canonical_owner_actor_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.resource_rights rr
       WHERE rr.resource_id = r.id
         AND rr.right_kind = 'OWN'
         AND rr.revoked_at IS NULL
         AND rr.expired_at IS NULL
         AND (rr.starts_at IS NULL OR rr.starts_at <= now())
         AND (rr.ends_at IS NULL OR rr.ends_at > now())
     );
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'r1_wire_missing_own backfill incomplete: % resources still missing OWN', v_missing;
  END IF;
  RAISE NOTICE 'r1_wire_missing_own backfill complete: 0 resources missing OWN';
END $$;
