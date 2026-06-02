-- Fix: cast_vote bloqueaba el INSERT cuando iOS no pasaba peso porque
-- `group_votes.weight` es NOT NULL DEFAULT 1, pero el INSERT explícito
-- pasaba `p_weight` (NULL por default) lo que override el column default.
-- Founder: "no puedo votar ni cambiar mi voto". Logs postgres muestran
-- `null value in column "weight" of relation "group_votes" violates
-- not-null constraint` al castear votos desde iOS.
--
-- Fix mínimo: COALESCE(p_weight, 1) — preserva path weighted (caller
-- pasa weight explícito) y arregla majority/supermajority/consensus
-- /consent/veto (caller no pasa weight).

CREATE OR REPLACE FUNCTION public.cast_vote(
    p_decision_id uuid,
    p_option_id uuid DEFAULT NULL::uuid,
    p_vote_value text DEFAULT NULL::text,
    p_reason text DEFAULT NULL::text,
    p_weight numeric DEFAULT NULL::numeric
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_uid           uuid := auth.uid();
  v_decision      public.group_decisions%ROWTYPE;
  v_membership_id uuid;
  v_value         text;
  v_vote_id       uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;
  SELECT * INTO v_decision FROM public.group_decisions WHERE id = p_decision_id;
  IF v_decision.id IS NULL THEN
    RAISE EXCEPTION 'decision % not found', p_decision_id USING errcode = 'P0002';
  END IF;
  IF v_decision.status <> 'open' THEN
    RAISE EXCEPTION 'decision % is not open (status=%)', p_decision_id, v_decision.status
      USING errcode = '22023';
  END IF;
  PERFORM public.assert_permission(v_decision.group_id, 'decisions.vote');

  SELECT id INTO v_membership_id FROM public.group_memberships
   WHERE group_id = v_decision.group_id AND user_id = v_uid AND status='active' LIMIT 1;
  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'voter is not an active member of group %', v_decision.group_id USING errcode = '42501';
  END IF;

  v_value := COALESCE(NULLIF(btrim(p_vote_value), ''), 'yes');
  IF v_value NOT IN ('yes','no','abstain','block') THEN
    RAISE EXCEPTION 'invalid vote value: %', v_value USING errcode = '22023';
  END IF;

  -- Append-only: nuevo INSERT por cada voto. El tally agrega el más
  -- reciente por miembro vía las tally functions.
  -- weight=COALESCE(p_weight, 1) respeta el column default cuando el
  -- caller no pasa peso (majority/supermajority/etc.); el caller
  -- weighted sigue pasando weight explícito.
  INSERT INTO public.group_votes (
    group_id, decision_id, voter_membership_id, option_id, vote_value, reason, weight
  ) VALUES (
    v_decision.group_id, p_decision_id, v_membership_id, p_option_id, v_value,
    NULLIF(btrim(COALESCE(p_reason,'')), ''),
    COALESCE(p_weight, 1)
  )
  RETURNING id INTO v_vote_id;

  PERFORM public.record_system_event(
    v_decision.group_id, 'decision.voted', 'decision', p_decision_id,
    'Voto registrado',
    jsonb_build_object('value', v_value, 'option_id', p_option_id, 'weight', COALESCE(p_weight, 1))
  );

  BEGIN
    PERFORM public._check_auto_finalize(p_decision_id);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN v_vote_id;
END;
$function$;
