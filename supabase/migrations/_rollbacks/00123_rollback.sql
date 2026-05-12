-- Rollback 00123 — restaurar finalize_vote v3 (00032). El bloque
-- fine_appeal se quita; las multas apeladas volverán a quedarse pegadas
-- en 'in_appeal' si se ejecuta este rollback en prod, así que SOLO
-- usar este rollback si la lógica v4 está rota — preferir un fix
-- forward.

create or replace function public.finalize_vote(p_vote_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote                public.votes%rowtype;
  v_in_favor            int;
  v_against             int;
  v_abstained           int;
  v_pending             int;
  v_total               int;
  v_voted               int;
  v_quorum_count        int;
  v_resolution          text;
  v_founder_user_id     uuid;
  v_founder_member_id   uuid;
  v_rule_id             uuid;
  v_rule_name           text;
  v_current_amount      int;
  v_proposed_amount     int;
begin
  select * into v_vote from public.votes where id = p_vote_id for update;
  if not found then
    raise exception 'vote not found' using errcode = '02000';
  end if;
  if v_vote.status <> 'open' then
    return coalesce(v_vote.payload->>'resolution', 'unknown');
  end if;

  select
    count(*) filter (where choice = 'in_favor'),
    count(*) filter (where choice = 'against'),
    count(*) filter (where choice = 'abstained'),
    count(*) filter (where choice = 'pending'),
    count(*)
  into v_in_favor, v_against, v_abstained, v_pending, v_total
  from public.vote_casts
  where vote_id = p_vote_id;

  v_voted        := v_in_favor + v_against + v_abstained;
  v_quorum_count := greatest(
    ceil(v_total::numeric * v_vote.quorum_percent / 100)::int,
    v_vote.quorum_min_absolute
  );

  if v_voted < v_quorum_count then
    v_resolution := 'quorum_failed';
  elsif v_in_favor::numeric * 100 >= (v_in_favor + v_against)::numeric * v_vote.threshold_percent then
    v_resolution := 'passed';
  else
    v_resolution := 'failed';
  end if;

  update public.votes
  set status      = case when v_resolution = 'quorum_failed' then 'quorum_failed' else 'resolved' end,
      resolved_at = now(),
      counts      = jsonb_build_object(
        'inFavor',        v_in_favor,
        'against',        v_against,
        'abstained',      v_abstained,
        'pending',        v_pending,
        'totalEligible',  v_total,
        'quorumRequired', v_quorum_count,
        'resolution',     v_resolution
      ),
      payload = payload || jsonb_build_object('resolution', v_resolution)
  where id = p_vote_id;

  insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
  values (
    v_vote.group_id, 'voteResolved', p_vote_id, null,
    jsonb_build_object('vote_type', v_vote.vote_type, 'reference_id', v_vote.reference_id, 'resolution', v_resolution)
  );

  insert into public.notifications_outbox (group_id, recipient_member_id, notification_type, payload, deep_link)
  select
    v_vote.group_id, vc.member_id, 'voteResolved',
    jsonb_build_object('vote_id', p_vote_id, 'vote_type', v_vote.vote_type, 'reference_id', v_vote.reference_id, 'resolution', v_resolution, 'title', v_vote.title),
    'ruul://vote/' || p_vote_id::text
  from public.vote_casts vc
  where vc.vote_id = p_vote_id;

  if v_vote.vote_type = 'fine_appeal' then
    insert into public.notifications_outbox (group_id, recipient_member_id, notification_type, payload, deep_link)
    select
      v_vote.group_id, (v_vote.payload->>'member_id')::uuid, 'voteResolved',
      jsonb_build_object('vote_id', p_vote_id, 'vote_type', v_vote.vote_type, 'reference_id', v_vote.reference_id, 'resolution', v_resolution, 'title', v_vote.title, 'is_appellant', true),
      'ruul://vote/' || p_vote_id::text
    where v_vote.payload ? 'member_id' and (v_vote.payload->>'member_id') <> '';
  end if;

  if v_vote.vote_type = 'rule_change' and v_resolution = 'passed' then
    v_current_amount  := nullif(v_vote.payload->>'current_amount', '')::int;
    v_proposed_amount := nullif(v_vote.payload->>'proposed_amount', '')::int;
    if v_current_amount is null or v_proposed_amount is null then
      return v_resolution;
    end if;

    select gm.id, gm.user_id into v_founder_member_id, v_founder_user_id
      from public.group_members gm
     where gm.group_id = v_vote.group_id and gm.roles ?| array['founder'] and gm.active = true
     order by gm.created_at asc limit 1;

    if v_founder_user_id is not null then
      v_rule_id := v_vote.reference_id;
      select coalesce(name, title, 'Regla #' || left(v_rule_id::text, 8)) into v_rule_name
        from public.rules where id = v_rule_id;
      v_rule_name := coalesce(v_rule_name, 'Regla #' || left(v_rule_id::text, 8));

      insert into public.user_actions (user_id, group_id, action_type, reference_id, title, body, priority)
      select v_founder_user_id, v_vote.group_id, 'ruleChangeApplyPending', p_vote_id,
             'Aplicar cambio aprobado: ' || v_rule_name,
             format('Votado: $%s → $%s', v_current_amount, v_proposed_amount), 'high'
      where not exists (select 1 from public.user_actions where reference_id = p_vote_id and action_type = 'ruleChangeApplyPending');

      insert into public.notifications_outbox (group_id, recipient_member_id, notification_type, payload, deep_link)
      values (
        v_vote.group_id, v_founder_member_id, 'ruleChangeApplyPending',
        jsonb_build_object('vote_id', p_vote_id, 'rule_id', v_rule_id, 'rule_name', v_rule_name,
                           'current_amount', v_current_amount, 'proposed_amount', v_proposed_amount,
                           'title', 'Aplicar cambio aprobado',
                           'body', format('Votado: $%s → $%s', v_current_amount, v_proposed_amount)),
        'ruul://rule/' || v_rule_id::text || '/edit?proposedAmount=' || v_proposed_amount::text
      );
    end if;
  end if;

  return v_resolution;
end;
$$;
