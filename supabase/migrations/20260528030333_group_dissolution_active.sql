-- 20260527210000 — Dissolution read surface (Primitiva 25, B8).
--
-- Write surface ya existe: propose_dissolution (gateado por
-- group.dissolve; auto-crea un vote supermajority 14 días),
-- approve_dissolution (set status=approved + approved_at — backend
-- lo dispara automáticamente cuando el vote linked pasa),
-- finalize_dissolution (gateado por group.dissolve; bloquea si hay
-- obligations abiertas; flip groups.status='dissolved' + memberships
-- 'left').
--
-- Lo que falta es el read RPC para que iOS sepa si hay disolución
-- activa (proposed/approved/liquidating) en este grupo. Devuelve
-- jsonb vacío {} cuando no hay activa; full row + initiator
-- display_name + linked decision id cuando sí.

CREATE OR REPLACE FUNCTION public.group_dissolution_active(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_row    public.group_dissolutions%rowtype;
  v_actor  text;
  v_open_obligations int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.group_memberships gm
     WHERE gm.group_id = p_group_id
       AND gm.user_id  = v_uid
       AND gm.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'caller is not an active member of group %', p_group_id
      USING errcode = '42501';
  END IF;

  SELECT * INTO v_row
    FROM public.group_dissolutions
   WHERE group_id = p_group_id
     AND status IN ('proposed','approved','liquidating')
   ORDER BY proposed_at DESC
   LIMIT 1;

  IF v_row.id IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT NULLIF(p.display_name, '') INTO v_actor
    FROM public.profiles p
   WHERE p.id = v_row.initiated_by;

  SELECT count(*) INTO v_open_obligations
    FROM public.group_obligations
   WHERE group_id = p_group_id
     AND status IN ('open','partially_settled');

  RETURN jsonb_build_object(
    'dissolution_id',          v_row.id,
    'group_id',                v_row.group_id,
    'initiated_by',            v_row.initiated_by,
    'initiated_by_display_name', v_actor,
    'source_decision_id',      v_row.source_decision_id,
    'status',                  v_row.status,
    'reason',                  v_row.reason,
    'plan',                    v_row.plan,
    'asset_disposition',       v_row.asset_disposition,
    'obligations_plan',        v_row.obligations_plan,
    'proposed_at',             v_row.proposed_at,
    'approved_at',             v_row.approved_at,
    'executed_at',             v_row.executed_at,
    'updated_at',              v_row.updated_at,
    'open_obligations_count',  v_open_obligations
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.group_dissolution_active(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.group_dissolution_active(uuid) TO authenticated;
COMMENT ON FUNCTION public.group_dissolution_active(uuid) IS
  'Primitiva 25 (mig 20260527210000): returns the active dissolution (proposed/approved/liquidating) for a group as jsonb, with initiator display name + linked decision + open_obligations_count. Empty object when none active. Active-member gate.';
