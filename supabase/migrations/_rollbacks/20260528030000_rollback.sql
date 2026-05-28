-- Rollback for 20260528030000_decision_metadata_membership_handler.
-- Restores start_vote to the 14-arg shape (sin p_metadata) and the
-- prior finalize_vote handler chain (sin la rama membership).

DROP FUNCTION IF EXISTS public.start_vote(
  uuid, text, text, text, text, text, timestamptz, timestamptz, numeric, numeric, boolean, text, uuid, jsonb, jsonb
);

CREATE OR REPLACE FUNCTION public.start_vote(
  p_group_id           uuid,
  p_title              text,
  p_body               text,
  p_decision_type      text,
  p_method             text,
  p_legitimacy_source  text     DEFAULT 'majority',
  p_opens_at           timestamptz DEFAULT NULL,
  p_closes_at          timestamptz DEFAULT NULL,
  p_threshold_pct      numeric  DEFAULT NULL,
  p_quorum_pct         numeric  DEFAULT NULL,
  p_committee_only     boolean  DEFAULT false,
  p_reference_kind     text     DEFAULT NULL,
  p_reference_id       uuid     DEFAULT NULL,
  p_options            jsonb    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_decision_id uuid;
  v_option    jsonb;
  v_sort      integer := 0;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'must be authenticated' USING errcode = '42501'; END IF;
  PERFORM public.assert_permission(p_group_id, 'decisions.propose');

  INSERT INTO public.group_decisions (
    group_id, title, body, decision_type, method, legitimacy_source,
    status, opens_at, closes_at, threshold_pct, quorum_pct,
    committee_only, reference_kind, reference_id, created_by
  ) VALUES (
    p_group_id, p_title, p_body, p_decision_type, p_method, p_legitimacy_source,
    'open', p_opens_at, p_closes_at, p_threshold_pct, p_quorum_pct,
    COALESCE(p_committee_only, false), p_reference_kind, p_reference_id, v_uid
  )
  RETURNING id INTO v_decision_id;

  IF p_options IS NOT NULL AND jsonb_typeof(p_options) = 'array' THEN
    FOR v_option IN SELECT * FROM jsonb_array_elements(p_options) LOOP
      INSERT INTO public.group_decision_options (decision_id, label, body, sort_order)
      VALUES (v_decision_id, COALESCE(v_option->>'label', ''), v_option->>'body', v_sort);
      v_sort := v_sort + 1;
    END LOOP;
  END IF;

  PERFORM public.record_system_event(
    p_group_id, 'decision.proposed', 'decision', v_decision_id, p_title,
    jsonb_build_object('decision_type', p_decision_type, 'method', p_method, 'reference_kind', p_reference_kind)
  );
  RETURN v_decision_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.start_vote(uuid, text, text, text, text, text, timestamptz, timestamptz, numeric, numeric, boolean, text, uuid, jsonb) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.start_vote(uuid, text, text, text, text, text, timestamptz, timestamptz, numeric, numeric, boolean, text, uuid, jsonb) TO authenticated;

-- finalize_vote (sin rama membership)
CREATE OR REPLACE FUNCTION public.finalize_vote(p_decision_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public' AS $$
declare
  v_d       public.group_decisions%rowtype;
  v_yes     numeric := 0;
  v_no      numeric := 0;
  v_abstain numeric := 0;
  v_block   numeric := 0;
  v_total   numeric;
  v_outcome text;
  v_quorum_total numeric;
  v_threshold numeric;
begin
  select * into v_d from public.group_decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then return v_d.status; end if;
  with current as (select distinct on (voter_membership_id) * from public.group_votes where decision_id = p_decision_id order by voter_membership_id, seq desc)
  select coalesce(sum(weight) filter (where vote_value = 'yes'), 0),
         coalesce(sum(weight) filter (where vote_value = 'no'), 0),
         coalesce(sum(weight) filter (where vote_value = 'abstain'), 0),
         coalesce(sum(weight) filter (where vote_value = 'block'), 0)
  into v_yes, v_no, v_abstain, v_block from current;
  v_total := v_yes + v_no + v_abstain + v_block;
  if v_d.quorum_pct is not null then
    select count(*) into v_quorum_total from public.group_memberships where group_id = v_d.group_id and status = 'active';
    if v_quorum_total = 0 or (v_total * 100.0 / v_quorum_total) < v_d.quorum_pct then v_outcome := 'no_quorum'; end if;
  end if;
  v_threshold := coalesce(v_d.threshold_pct, case v_d.method when 'consensus' then 100 when 'supermajority' then 66.66 when 'consent' then 100 else 50.01 end);
  if v_outcome is null then
    if v_d.method = 'consent' and v_block > 0 then v_outcome := 'rejected';
    elsif (v_yes + v_no) > 0 and (v_yes * 100.0 / (v_yes + v_no)) >= v_threshold then v_outcome := 'passed';
    else v_outcome := 'rejected'; end if;
  end if;
  update public.group_decisions set status = case when v_outcome = 'passed' then 'passed' else 'rejected' end,
    decided_at = now(),
    result = jsonb_build_object('yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block, 'outcome', v_outcome)
   where id = p_decision_id;
  if v_outcome = 'passed' then
    if v_d.reference_kind = 'sanction' and v_d.reference_id is not null then perform public.update_sanction_status(v_d.reference_id, 'reversed', 'vote_pass');
    elsif v_d.reference_kind = 'dispute' and v_d.reference_id is not null then update public.group_disputes set status = 'resolved', resolved_at = now() where id = v_d.reference_id;
    elsif v_d.reference_kind = 'mandate_grant' and v_d.reference_id is not null then update public.group_mandates set source_decision_id = p_decision_id where id = v_d.reference_id;
    elsif v_d.reference_kind = 'mandate_revoke' and v_d.reference_id is not null then perform public.revoke_mandate(v_d.reference_id, 'vote_pass');
    elsif v_d.reference_kind = 'dissolution' and v_d.reference_id is not null then perform public.approve_dissolution(v_d.reference_id);
    end if;
  end if;
  perform public.record_system_event(v_d.group_id, 'decision.finalized', 'decision', p_decision_id, v_outcome,
    jsonb_build_object('yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block));
  return v_outcome;
end;
$$;
