-- approve_dissolution first so finalize_vote can call it
create or replace function public.approve_dissolution(p_dissolution_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_dissolutions%rowtype;
begin
  select * into v_d from public.group_dissolutions where id = p_dissolution_id for update;
  if v_d.id is null then raise exception 'dissolution not found'; end if;
  update public.group_dissolutions
     set status = 'approved', approved_at = now()
   where id = p_dissolution_id;

  perform public.record_system_event(
    v_d.group_id, 'dissolution.approved', 'dissolution', p_dissolution_id, null, '{}'::jsonb
  );
end;
$$;

-- finalize_vote (depends on update_sanction_status + approve_dissolution + revoke_mandate)
create or replace function public.finalize_vote(p_decision_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
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
    end if;
  end if;

  perform public.record_system_event(
    v_d.group_id, 'decision.finalized', 'decision', p_decision_id, v_outcome,
    jsonb_build_object('yes', v_yes, 'no', v_no, 'abstain', v_abstain, 'block', v_block)
  );

  return v_outcome;
end;
$$;

-- §13. Reputation
create or replace function public.record_reputation_event(
  p_group_id            uuid,
  p_subject_membership_id uuid,
  p_reputation_type     text,
  p_reason              text default null,
  p_evidence_entity_kind text default null,
  p_evidence_entity_id  uuid default null,
  p_visibility          text default 'members'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_actor uuid;
begin
  perform public.assert_permission(p_group_id, 'reputation.record');
  v_actor := (select id from public.group_memberships where group_id = p_group_id and user_id = auth.uid());
  insert into public.group_reputation_events (
    group_id, subject_membership_id, actor_membership_id,
    reputation_type, reason, evidence_entity_kind, evidence_entity_id, visibility
  ) values (
    p_group_id, p_subject_membership_id, v_actor,
    p_reputation_type, p_reason, p_evidence_entity_kind, p_evidence_entity_id, p_visibility
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.retract_reputation_event(
  p_event_id uuid,
  p_reason   text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_e public.group_reputation_events%rowtype; v_actor uuid;
begin
  select * into v_e from public.group_reputation_events where id = p_event_id;
  if v_e.id is null then raise exception 'reputation event not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_e.group_id and user_id = auth.uid());
  if v_e.actor_membership_id <> v_actor and not public.has_group_permission(v_e.group_id, 'reputation.record') then
    raise exception 'caller cannot retract this event';
  end if;
  update public.group_reputation_events
     set status = 'retracted',
         metadata = metadata || jsonb_build_object('retraction_reason', p_reason)
   where id = p_event_id;
end;
$$;

-- §14. Culture
create or replace function public.propose_norm(
  p_group_id  uuid,
  p_norm_type text,
  p_title     text,
  p_body      text default null,
  p_visibility text default 'members'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.assert_permission(p_group_id, 'culture.propose');
  insert into public.group_cultural_norms (
    group_id, norm_type, title, body, visibility, status, proposed_by
  ) values (
    p_group_id, p_norm_type, p_title, p_body, p_visibility, 'proposed', auth.uid()
  ) returning id into v_id;

  perform public.record_system_event(
    p_group_id, 'norm.proposed', 'norm', v_id, p_title,
    jsonb_build_object('norm_type', p_norm_type)
  );
  return v_id;
end;
$$;

create or replace function public.endorse_norm(p_norm_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_n public.group_cultural_norms%rowtype; v_threshold int;
begin
  select * into v_n from public.group_cultural_norms where id = p_norm_id for update;
  if v_n.id is null then raise exception 'norm not found'; end if;
  perform public.assert_permission(v_n.group_id, 'culture.endorse');

  update public.group_cultural_norms set endorsed_count = endorsed_count + 1 where id = p_norm_id;

  select coalesce(((settings->>'norm_endorse_threshold')::int), 3) into v_threshold
    from public.groups where id = v_n.group_id;

  if v_n.endorsed_count + 1 >= v_threshold and v_n.status = 'proposed' then
    update public.group_cultural_norms set status = 'endorsed' where id = p_norm_id;
    perform public.record_system_event(
      v_n.group_id, 'norm.endorsed', 'norm', p_norm_id, v_n.title, '{}'::jsonb
    );
  end if;
end;
$$;

create or replace function public.retire_norm(p_norm_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_n public.group_cultural_norms%rowtype;
begin
  select * into v_n from public.group_cultural_norms where id = p_norm_id for update;
  if v_n.id is null then raise exception 'norm not found'; end if;
  if v_n.proposed_by <> auth.uid() and not public.has_group_permission(v_n.group_id, 'culture.endorse') then
    raise exception 'caller cannot retire this norm';
  end if;
  update public.group_cultural_norms
     set status = 'retired',
         metadata = metadata || jsonb_build_object('retire_reason', p_reason)
   where id = p_norm_id;
  perform public.record_system_event(
    v_n.group_id, 'norm.retired', 'norm', p_norm_id, p_reason, '{}'::jsonb
  );
end;
$$;

-- §15. Dissolution
create or replace function public.propose_dissolution(
  p_group_id          uuid,
  p_reason            text,
  p_plan              jsonb default '{}'::jsonb,
  p_asset_disposition jsonb default '{}'::jsonb,
  p_obligations_plan  jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_decision uuid;
begin
  perform public.assert_permission(p_group_id, 'group.dissolve');
  insert into public.group_dissolutions (
    group_id, initiated_by, status, reason, plan, asset_disposition, obligations_plan
  ) values (
    p_group_id, auth.uid(), 'proposed', p_reason,
    coalesce(p_plan, '{}'::jsonb), coalesce(p_asset_disposition, '{}'::jsonb),
    coalesce(p_obligations_plan, '{}'::jsonb)
  ) returning id into v_id;

  v_decision := public.start_vote(
    p_group_id, 'Disolución del grupo', p_reason,
    'dissolution', 'supermajority', 'supermajority',
    null, now() + interval '14 days', 66.66, 50,
    false, 'dissolution', v_id, null
  );

  update public.group_dissolutions set source_decision_id = v_decision where id = v_id;
  update public.groups set status = 'dissolving' where id = p_group_id;

  perform public.record_system_event(
    p_group_id, 'dissolution.proposed', 'dissolution', v_id, p_reason,
    jsonb_build_object('decision_id', v_decision)
  );
  return v_id;
end;
$$;

create or replace function public.record_liquidation_step(
  p_dissolution_id uuid,
  p_step_kind      text,
  p_payload        jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_dissolutions%rowtype;
begin
  select * into v_d from public.group_dissolutions where id = p_dissolution_id for update;
  if v_d.id is null then raise exception 'dissolution not found'; end if;
  perform public.assert_permission(v_d.group_id, 'group.dissolve');

  update public.group_dissolutions
     set plan = jsonb_set(
                  coalesce(plan, '{}'::jsonb),
                  '{steps}',
                  coalesce(plan->'steps', '[]'::jsonb) ||
                    jsonb_build_array(jsonb_build_object(
                      'kind', p_step_kind, 'at', now(), 'payload', coalesce(p_payload, '{}'::jsonb)
                    )),
                  true
                )
   where id = p_dissolution_id;

  perform public.record_system_event(
    v_d.group_id, 'dissolution.step', 'dissolution', p_dissolution_id, p_step_kind, coalesce(p_payload, '{}'::jsonb)
  );
end;
$$;

create or replace function public.finalize_dissolution(p_dissolution_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_dissolutions%rowtype; v_open int;
begin
  select * into v_d from public.group_dissolutions where id = p_dissolution_id for update;
  if v_d.id is null then raise exception 'dissolution not found'; end if;
  perform public.assert_permission(v_d.group_id, 'group.dissolve');

  select count(*) into v_open from public.group_obligations
   where group_id = v_d.group_id and status in ('open','partially_settled');
  if v_open > 0 then raise exception 'cannot finalize: % obligations still open', v_open; end if;

  update public.group_dissolutions
     set status = 'executed', executed_at = now()
   where id = p_dissolution_id;

  update public.groups
     set status = 'dissolved', dissolved_at = now()
   where id = v_d.group_id;

  update public.group_memberships
     set status = 'left', left_at = now(), left_reason = 'dissolution'
   where group_id = v_d.group_id and status = 'active';

  perform public.record_system_event(
    v_d.group_id, 'dissolution.finalized', 'dissolution', p_dissolution_id, null, '{}'::jsonb
  );
end;
$$;

-- §16. Memory & read helpers
create or replace function public.member_balance_in_group(
  p_group_id      uuid,
  p_membership_id uuid
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select sum(case
                  when transaction_type in ('contribution','income','refund','reversal') then amount
                  when transaction_type in ('expense','payout') and from_membership_id = p_membership_id then -amount
                  else 0
                end)
       from public.group_resource_transactions
       where group_id = p_group_id
         and (from_membership_id = p_membership_id or to_membership_id = p_membership_id or paid_by_membership_id = p_membership_id)
    ), 0
  )
  - coalesce(
    (select sum(amount_outstanding)
       from public.group_obligations
       where group_id = p_group_id and owed_by_membership_id = p_membership_id
         and status in ('open','partially_settled')
    ), 0
  );
$$;

create or replace function public.member_obligation_summary(
  p_group_id      uuid,
  p_membership_id uuid
)
returns table (
  obligation_id      uuid,
  kind               text,
  amount_outstanding numeric,
  owed_to_kind       text,
  owed_to_label      text
)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.obligation_kind, o.amount_outstanding, o.owed_to_kind,
         coalesce(p.display_name, p.username, o.owed_to_kind)
  from public.group_obligations o
  left join public.group_memberships m on m.id = o.owed_to_membership_id
  left join public.profiles p on p.id = m.user_id
  where o.group_id = p_group_id
    and o.owed_by_membership_id = p_membership_id
    and o.status in ('open','partially_settled')
  order by o.created_at;
$$;

create or replace function public.current_votes_for_decision(p_decision_id uuid)
returns setof public.group_votes
language sql
stable
security definer
set search_path = public
as $$
  select distinct on (voter_membership_id) *
  from public.group_votes
  where decision_id = p_decision_id
  order by voter_membership_id, seq desc;
$$;

create or replace function public.group_summary(p_group_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'group_id', p_group_id,
    'member_count', (select count(*) from public.group_memberships where group_id = p_group_id and status = 'active'),
    'open_decisions', (select count(*) from public.group_decisions where group_id = p_group_id and status = 'open'),
    'open_disputes', (select count(*) from public.group_disputes where group_id = p_group_id and status in ('open','in_review','mediation')),
    'open_obligations', (select count(*) from public.group_obligations where group_id = p_group_id and status in ('open','partially_settled')),
    'recent_events', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'event_type', e.event_type, 'summary', e.summary, 'occurred_at', e.occurred_at) order by e.id desc), '[]'::jsonb)
      from (
        select id, event_type, summary, occurred_at
        from public.group_events
        where group_id = p_group_id
        order by id desc
        limit 20
      ) e
    )
  );
$$;

-- §17. GDPR export/delete
create or replace function public.delete_and_export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_export jsonb;
begin
  if v_uid is null then raise exception 'must be authenticated'; end if;

  v_export := jsonb_build_object(
    'profile', (select to_jsonb(p) from public.profiles p where p.id = v_uid),
    'memberships', (select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) from public.group_memberships m where m.user_id = v_uid),
    'contributions', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from public.group_contributions c join public.group_memberships m on m.id = c.membership_id where m.user_id = v_uid),
    'votes', (select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) from public.group_votes v join public.group_memberships m on m.id = v.voter_membership_id where m.user_id = v_uid),
    'exported_at', now()
  );

  update public.group_mandates
     set status = 'revoked', revoked_at = now(), revoked_reason = 'user_deleted'
   where representative_membership_id in (select id from public.group_memberships where user_id = v_uid)
     and status = 'active';

  update public.group_memberships
     set status = 'left', left_at = now(), left_reason = 'user_deleted'
   where user_id = v_uid and status = 'active';

  update public.profiles
     set deleted_at = now(), display_name = null, avatar_url = null, bio = null
   where id = v_uid;

  return v_export;
end;
$$;

-- §18. Lockdown — revoke EXECUTE on internal helpers from anon
revoke execute on function public.record_system_event(uuid, text, text, uuid, text, jsonb) from anon, public;
revoke execute on function public.evaluate_rules_for_event(uuid)                              from anon, public;
revoke execute on function public.approve_dissolution(uuid)                                   from anon, public;
