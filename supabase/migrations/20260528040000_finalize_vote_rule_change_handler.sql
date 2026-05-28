-- 20260528040000 — V2-G2 sub-slice 5: rule_change handler en finalize_vote.
--
-- Extiende el switch de finalize_vote para que cuando
-- reference_kind='rule' + outcome=passed + reference_id != NULL,
-- aplique la mutación que el proposer dejó en metadata.action:
--   - 'archive': flips group_rules.status='archived' + cierra la
--     versión vigente (effective_until=now()). Emite rule.archived.
--   - 'activate': flips group_rules.status='active' cuando viene de
--     'archived' o 'draft'. Emite rule.activated.
--   - cualquier otro valor (incluido NULL): no-op silencioso. Se
--     registra en el system event para audit.
--
-- Patrón inline (no llama archive_rule porque el RPC asserta el
-- permission 'rules.archive' del caller — la legitimidad acá viene
-- del voto, no de un permiso individual; mismo precedente que la
-- rama mandate_grant que ya actualiza group_mandates directo).

CREATE OR REPLACE FUNCTION public.finalize_vote(p_decision_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
  v_d                public.group_decisions%rowtype;
  v_yes              numeric := 0;
  v_no               numeric := 0;
  v_abstain          numeric := 0;
  v_block            numeric := 0;
  v_total            numeric;
  v_outcome          text;
  v_quorum_total     numeric;
  v_threshold        numeric;
  v_target_state     text;
  v_rule_action      text;
  v_rule             public.group_rules%rowtype;
begin
  select * into v_d from public.group_decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then return v_d.status; end if;

  with current as (
    select distinct on (voter_membership_id) *
    from public.group_votes
    where decision_id = p_decision_id
    order by voter_membership_id, seq desc
  )
  select
    coalesce(sum(weight) filter (where vote_value = 'yes'), 0),
    coalesce(sum(weight) filter (where vote_value = 'no'), 0),
    coalesce(sum(weight) filter (where vote_value = 'abstain'), 0),
    coalesce(sum(weight) filter (where vote_value = 'block'), 0)
  into v_yes, v_no, v_abstain, v_block from current;

  v_total := v_yes + v_no + v_abstain + v_block;

  if v_d.quorum_pct is not null then
    select count(*) into v_quorum_total
    from public.group_memberships
    where group_id = v_d.group_id and status = 'active';
    if v_quorum_total = 0 or (v_total * 100.0 / v_quorum_total) < v_d.quorum_pct then
      v_outcome := 'no_quorum';
    end if;
  end if;

  v_threshold := coalesce(v_d.threshold_pct,
                          case v_d.method
                            when 'consensus'    then 100
                            when 'supermajority' then 66.66
                            when 'consent'      then 100
                            else 50.01
                          end);

  if v_outcome is null then
    if v_d.method = 'consent' and v_block > 0 then
      v_outcome := 'rejected';
    elsif (v_yes + v_no) > 0 and (v_yes * 100.0 / (v_yes + v_no)) >= v_threshold then
      v_outcome := 'passed';
    else
      v_outcome := 'rejected';
    end if;
  end if;

  update public.group_decisions
     set status = case when v_outcome = 'passed' then 'passed' else 'rejected' end,
         decided_at = now(),
         result = jsonb_build_object('yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block, 'outcome', v_outcome)
   where id = p_decision_id;

  if v_outcome = 'passed' then
    if v_d.reference_kind = 'sanction' and v_d.reference_id is not null then
      perform public.update_sanction_status(v_d.reference_id, 'reversed', 'vote_pass');
    elsif v_d.reference_kind = 'dispute' and v_d.reference_id is not null then
      update public.group_disputes set status = 'resolved', resolved_at = now() where id = v_d.reference_id;
    elsif v_d.reference_kind = 'mandate_grant' and v_d.reference_id is not null then
      update public.group_mandates set source_decision_id = p_decision_id where id = v_d.reference_id;
    elsif v_d.reference_kind = 'mandate_revoke' and v_d.reference_id is not null then
      perform public.revoke_mandate(v_d.reference_id, 'vote_pass');
    elsif v_d.reference_kind = 'dissolution' and v_d.reference_id is not null then
      perform public.approve_dissolution(v_d.reference_id);
    elsif v_d.reference_kind = 'membership' and v_d.reference_id is not null then
      v_target_state := NULLIF(v_d.metadata->>'target_state', '');
      if v_target_state IN ('active','suspended','expelled','inactive') then
        perform public.set_membership_state(
          v_d.reference_id,
          v_target_state,
          'vote_pass'
        );
      end if;
    elsif v_d.reference_kind = 'rule' and v_d.reference_id is not null then
      -- V2-G2 sub-slice 5 — inline rule mutation gated by the vote,
      -- not by the finalizer's individual rules.archive permission.
      v_rule_action := NULLIF(v_d.metadata->>'action', '');
      select * into v_rule from public.group_rules where id = v_d.reference_id for update;
      if v_rule.id is not null then
        if v_rule_action = 'archive' and v_rule.status <> 'archived' then
          update public.group_rules
             set status     = 'archived',
                 updated_at = now()
           where id = v_rule.id;
          if v_rule.current_version_id is not null then
            update public.group_rule_versions
               set effective_until = now()
             where id = v_rule.current_version_id
               and effective_until is null;
          end if;
          perform public.record_system_event(
            v_rule.group_id, 'rule.archived', 'rule', v_rule.id,
            'Regla archivada por decisión',
            jsonb_build_object('source', 'decision', 'decision_id', p_decision_id)
          );
        elsif v_rule_action = 'activate' and v_rule.status IN ('archived','draft') then
          update public.group_rules
             set status     = 'active',
                 updated_at = now()
           where id = v_rule.id;
          perform public.record_system_event(
            v_rule.group_id, 'rule.activated', 'rule', v_rule.id,
            'Regla reactivada por decisión',
            jsonb_build_object('source', 'decision', 'decision_id', p_decision_id)
          );
        end if;
      end if;
    end if;
  end if;

  perform public.record_system_event(
    v_d.group_id, 'decision.finalized', 'decision', p_decision_id, v_outcome,
    jsonb_build_object('yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block,
                       'reference_kind', v_d.reference_kind,
                       'target_state', v_d.metadata->>'target_state',
                       'rule_action',  v_d.metadata->>'action')
  );

  return v_outcome;
end;
$$;
