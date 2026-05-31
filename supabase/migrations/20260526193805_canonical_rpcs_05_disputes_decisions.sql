-- §11. Disputes
create or replace function public.open_dispute(
  p_group_id              uuid,
  p_subject_kind          text,
  p_subject_id            uuid,
  p_title                 text,
  p_description           text default null,
  p_respondent_membership_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_opener uuid;
begin
  perform public.assert_permission(p_group_id, 'disputes.open');
  v_opener := public.assert_member_of_group(p_group_id);

  insert into public.group_disputes (
    group_id, opened_by_membership_id, respondent_membership_id,
    subject_kind, subject_id, title, description, status
  ) values (
    p_group_id, v_opener, p_respondent_membership_id,
    p_subject_kind, p_subject_id, p_title, p_description, 'open'
  ) returning id into v_id;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body)
  values (v_id, v_opener, 'comment', p_description);

  perform public.record_system_event(
    p_group_id, 'dispute.opened', 'dispute', v_id, p_title,
    jsonb_build_object('subject_kind', p_subject_kind, 'subject_id', p_subject_id)
  );
  return v_id;
end;
$$;

create or replace function public.assign_mediator(
  p_dispute_id            uuid,
  p_mediator_membership_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_group uuid;
begin
  select group_id into v_group from public.group_disputes where id = p_dispute_id for update;
  if v_group is null then raise exception 'dispute not found'; end if;
  perform public.assert_permission(v_group, 'disputes.mediate');

  update public.group_disputes
     set mediator_membership_id = p_mediator_membership_id, status = 'mediation'
   where id = p_dispute_id;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body)
  values (p_dispute_id, p_mediator_membership_id, 'status_change', 'Mediador asignado');

  perform public.record_system_event(
    v_group, 'dispute.mediator_assigned', 'dispute', p_dispute_id, null,
    jsonb_build_object('mediator', p_mediator_membership_id)
  );
end;
$$;

create or replace function public.append_dispute_event(
  p_dispute_id uuid,
  p_event_type text,
  p_body       text,
  p_metadata   jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_disputes%rowtype; v_actor uuid; v_id uuid;
begin
  select * into v_d from public.group_disputes where id = p_dispute_id;
  if v_d.id is null then raise exception 'dispute not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_d.group_id and user_id = auth.uid() and status = 'active');
  if v_actor is null then raise exception 'caller is not a member'; end if;

  if v_actor not in (v_d.opened_by_membership_id, v_d.respondent_membership_id, v_d.mediator_membership_id)
     and not public.has_group_permission(v_d.group_id, 'disputes.mediate') then
    raise exception 'caller cannot append to this dispute';
  end if;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body, metadata)
  values (p_dispute_id, v_actor, p_event_type, p_body, coalesce(p_metadata, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.record_dispute_resolution(
  p_dispute_id      uuid,
  p_method          text,
  p_resolution_text text,
  p_outcome         jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_disputes%rowtype; v_actor uuid;
begin
  select * into v_d from public.group_disputes where id = p_dispute_id for update;
  if v_d.id is null then raise exception 'dispute not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_d.group_id and user_id = auth.uid());
  if v_d.mediator_membership_id <> v_actor and not public.has_group_permission(v_d.group_id, 'disputes.resolve') then
    raise exception 'caller cannot resolve this dispute';
  end if;

  update public.group_disputes
     set status = 'resolved', resolution_method = p_method, resolution = p_resolution_text, resolved_at = now()
   where id = p_dispute_id;

  insert into public.group_dispute_events (dispute_id, actor_membership_id, event_type, body, metadata)
  values (p_dispute_id, v_actor, 'resolution', p_resolution_text, coalesce(p_outcome, '{}'::jsonb));

  if v_d.subject_kind = 'sanction' and p_outcome ? 'reverse_sanction' then
    perform public.update_sanction_status(v_d.subject_id, 'reversed', 'dispute_resolution');
  end if;

  insert into public.group_reputation_events (group_id, subject_membership_id, actor_membership_id, reputation_type, reason, evidence_entity_kind, evidence_entity_id)
  select v_d.group_id, m, v_actor, 'conflict_resolved', p_resolution_text, 'dispute', p_dispute_id
  from unnest(ARRAY[v_d.opened_by_membership_id, v_d.respondent_membership_id]) as m
  where m is not null;

  perform public.record_system_event(
    v_d.group_id, 'dispute.resolved', 'dispute', p_dispute_id, p_resolution_text,
    coalesce(p_outcome, '{}'::jsonb)
  );
end;
$$;

-- §12. Decisions (needed BEFORE escalate_dispute_to_vote)
create or replace function public.start_vote(
  p_group_id          uuid,
  p_title             text,
  p_body              text,
  p_decision_type     text,
  p_method            text,
  p_legitimacy_source text default 'majority',
  p_opens_at          timestamptz default null,
  p_closes_at         timestamptz default null,
  p_threshold_pct     numeric default null,
  p_quorum_pct        numeric default null,
  p_committee_only    boolean default false,
  p_reference_kind    text default null,
  p_reference_id      uuid default null,
  p_options           jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_opt jsonb; v_sort int := 0;
begin
  perform public.assert_permission(p_group_id, 'decisions.create');

  insert into public.group_decisions (
    group_id, title, body, decision_type, method, legitimacy_source,
    status, threshold_pct, quorum_pct, committee_only,
    reference_kind, reference_id, opens_at, closes_at, created_by
  ) values (
    p_group_id, p_title, p_body, p_decision_type, p_method, p_legitimacy_source,
    'open', p_threshold_pct, p_quorum_pct, p_committee_only,
    p_reference_kind, p_reference_id,
    coalesce(p_opens_at, now()), p_closes_at, auth.uid()
  ) returning id into v_id;

  if p_options is not null then
    for v_opt in select * from jsonb_array_elements(p_options)
    loop
      insert into public.group_decision_options (decision_id, label, body, sort_order)
      values (v_id, v_opt->>'label', v_opt->>'body', v_sort);
      v_sort := v_sort + 1;
    end loop;
  end if;

  perform public.record_system_event(
    p_group_id, 'decision.started', 'decision', v_id, p_title,
    jsonb_build_object('method', p_method, 'closes_at', p_closes_at)
  );
  return v_id;
end;
$$;

create or replace function public.cast_vote(
  p_decision_id uuid,
  p_option_id   uuid default null,
  p_vote_value  text default null,
  p_weight      numeric default 1,
  p_reason      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_decisions%rowtype; v_voter uuid; v_id uuid;
begin
  select * into v_d from public.group_decisions where id = p_decision_id;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then raise exception 'decision is not open'; end if;
  if v_d.closes_at is not null and v_d.closes_at < now() then raise exception 'voting window closed'; end if;
  perform public.assert_permission(v_d.group_id, 'decisions.vote');
  v_voter := public.assert_member_of_group(v_d.group_id);

  insert into public.group_votes (
    group_id, decision_id, voter_membership_id, option_id, vote_value, weight, reason
  ) values (
    v_d.group_id, p_decision_id, v_voter, p_option_id, p_vote_value, coalesce(p_weight, 1), p_reason
  ) returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.cancel_vote(
  p_decision_id uuid,
  p_reason      text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_decisions%rowtype;
begin
  select * into v_d from public.group_decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found'; end if;
  perform public.assert_permission(v_d.group_id, 'decisions.resolve');

  update public.group_decisions
     set status = 'cancelled', decided_at = now(),
         result = result || jsonb_build_object('cancel_reason', p_reason)
   where id = p_decision_id;

  perform public.record_system_event(
    v_d.group_id, 'decision.cancelled', 'decision', p_decision_id, p_reason, '{}'::jsonb
  );
end;
$$;

create or replace function public.current_vote_for(
  p_decision_id        uuid,
  p_voter_membership_id uuid
)
returns public.group_votes
language sql
stable
security definer
set search_path = public
as $$
  select * from public.group_votes
   where decision_id = p_decision_id and voter_membership_id = p_voter_membership_id
   order by seq desc limit 1;
$$;

-- escalate_dispute_to_vote (depends on start_vote)
create or replace function public.escalate_dispute_to_vote(
  p_dispute_id        uuid,
  p_decision_title    text,
  p_decision_method   text,
  p_closes_at         timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_d public.group_disputes%rowtype; v_decision uuid; v_actor uuid;
begin
  select * into v_d from public.group_disputes where id = p_dispute_id for update;
  if v_d.id is null then raise exception 'dispute not found'; end if;
  v_actor := (select id from public.group_memberships where group_id = v_d.group_id and user_id = auth.uid());
  if v_d.mediator_membership_id <> v_actor then
    raise exception 'only the assigned mediator can escalate';
  end if;

  v_decision := public.start_vote(
    v_d.group_id, p_decision_title, v_d.description,
    'sanction_appeal', p_decision_method, 'majority',
    null, p_closes_at, null, null, false,
    'dispute', p_dispute_id, null
  );

  update public.group_disputes
     set status = 'escalated', escalated_decision_id = v_decision
   where id = p_dispute_id;

  perform public.record_system_event(
    v_d.group_id, 'dispute.escalated', 'dispute', p_dispute_id, null,
    jsonb_build_object('decision_id', v_decision)
  );
  return v_decision;
end;
$$;

-- dispute_sanction (depends on open_dispute)
create or replace function public.dispute_sanction(
  p_sanction_id uuid,
  p_summary     text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_s public.group_sanctions%rowtype; v_target_user uuid; v_id uuid;
begin
  select * into v_s from public.group_sanctions where id = p_sanction_id;
  if v_s.id is null then raise exception 'sanction not found'; end if;
  select user_id into v_target_user from public.group_memberships where id = v_s.target_membership_id;
  if v_target_user <> auth.uid() and not public.has_group_permission(v_s.group_id, 'sanctions.dispute') then
    raise exception 'caller cannot dispute this sanction';
  end if;

  v_id := public.open_dispute(v_s.group_id, 'sanction', p_sanction_id,
                              'Disputa de sanción', p_summary, null);
  update public.group_sanctions set dispute_id = v_id, status = 'disputed' where id = p_sanction_id;
  return v_id;
end;
$$;
