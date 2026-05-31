-- 00032 — finalize_vote v3: emite ruleChangeApplyPending UserAction
--          y outbox row con deep_link cuando rule_change resuelve passed.
--
-- Garantiza low-friction manual application: el founder recibe inbox
-- row + push con deep_link 'ruul://rule/<uuid>/edit?proposedAmount=<int>'
-- que lleva a EditRuleSheet pre-cargado con el amount propuesto.
-- Sin esto, el founder se olvida de aplicar el cambio aprobado y el
-- trust se erosiona.
--
-- Cambios vs v2 (00023):
--   1. Agrega bloque al final que detecta vote_type='rule_change' AND
--      v_resolution='passed'.
--   2. Resuelve founder vía group_members.roles ?| array['founder'].
--   3. INSERT user_actions con NOT EXISTS check (idempotente).
--   4. INSERT notifications_outbox con deep_link.
--
-- V2 contracts intactos: voteResolved system_event + outbox fan-out
-- a todos los voters siguen igual.

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
    v_vote.group_id,
    'voteResolved',
    p_vote_id,
    null,
    jsonb_build_object(
      'vote_type',    v_vote.vote_type,
      'reference_id', v_vote.reference_id,
      'resolution',   v_resolution
    )
  );

  -- Notification fan-out a todos los voters originales (existing).
  insert into public.notifications_outbox (
    group_id, recipient_member_id, notification_type, payload, deep_link
  )
  select
    v_vote.group_id,
    vc.member_id,
    'voteResolved',
    jsonb_build_object(
      'vote_id',      p_vote_id,
      'vote_type',    v_vote.vote_type,
      'reference_id', v_vote.reference_id,
      'resolution',   v_resolution,
      'title',        v_vote.title
    ),
    'ruul://vote/' || p_vote_id::text
  from public.vote_casts vc
  where vc.vote_id = p_vote_id;

  -- Para fine_appeal: notificar al appellant (existing).
  if v_vote.vote_type = 'fine_appeal' then
    insert into public.notifications_outbox (
      group_id, recipient_member_id, notification_type, payload, deep_link
    )
    select
      v_vote.group_id,
      (v_vote.payload->>'member_id')::uuid,
      'voteResolved',
      jsonb_build_object(
        'vote_id',      p_vote_id,
        'vote_type',    v_vote.vote_type,
        'reference_id', v_vote.reference_id,
        'resolution',   v_resolution,
        'title',        v_vote.title,
        'is_appellant', true
      ),
      'ruul://vote/' || p_vote_id::text
    where v_vote.payload ? 'member_id'
      and (v_vote.payload->>'member_id') <> '';
  end if;

  -- NUEVO V3: rule_change resuelto passed → user_action al founder + outbox push.
  if v_vote.vote_type = 'rule_change' and v_resolution = 'passed' then
    -- Read amounts first; skip v3 emit if payload malformed (defensive
    -- against rule_change votes whose payload didn't include amounts —
    -- e.g. future non-amount rule changes, or a propose_rule bug).
    v_current_amount  := nullif(v_vote.payload->>'current_amount', '')::int;
    v_proposed_amount := nullif(v_vote.payload->>'proposed_amount', '')::int;

    if v_current_amount is null or v_proposed_amount is null then
      -- Don't emit ruleChangeApplyPending if we can't render the deep_link
      -- or body amounts. The voteResolved fan-out (above) still notifies
      -- voters; the founder just won't get the specific apply-pending row.
      return v_resolution;
    end if;

    -- If a group has multiple co-founders, pick the earliest-joined
    -- (deterministic). v4 may fan out to all founders if co-founder
    -- groups become common.
    select gm.id, gm.user_id
      into v_founder_member_id, v_founder_user_id
      from public.group_members gm
     where gm.group_id = v_vote.group_id
       and gm.roles ?| array['founder']
       and gm.active = true
     order by gm.created_at asc
     limit 1;

    if v_founder_user_id is not null then
      v_rule_id         := v_vote.reference_id;

      select coalesce(name, title, 'Regla #' || left(v_rule_id::text, 8))
        into v_rule_name
        from public.rules
       where id = v_rule_id;

      v_rule_name := coalesce(v_rule_name, 'Regla #' || left(v_rule_id::text, 8));

      insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
      )
      select
        v_founder_user_id, v_vote.group_id, 'ruleChangeApplyPending', p_vote_id,
        'Aplicar cambio aprobado: ' || v_rule_name,
        format('Votado: $%s → $%s', v_current_amount, v_proposed_amount),
        'high'
      where not exists (
        select 1 from public.user_actions
         where reference_id = p_vote_id
           and action_type = 'ruleChangeApplyPending'
      );

      insert into public.notifications_outbox (
        group_id, recipient_member_id, notification_type, payload, deep_link
      )
      values (
        v_vote.group_id,
        v_founder_member_id,
        'ruleChangeApplyPending',
        jsonb_build_object(
          'vote_id',         p_vote_id,
          'rule_id',         v_rule_id,
          'rule_name',       v_rule_name,
          'current_amount',  v_current_amount,
          'proposed_amount', v_proposed_amount,
          'title',           'Aplicar cambio aprobado',
          'body',            format('Votado: $%s → $%s', v_current_amount, v_proposed_amount)
        ),
        'ruul://rule/' || v_rule_id::text || '/edit?proposedAmount=' || v_proposed_amount::text
      );
    end if;
  end if;

  return v_resolution;
end;
$$;

comment on function public.finalize_vote is
  'Closes vote, computes resolution. v3: para rule_change passed, inserta user_action ruleChangeApplyPending al founder + outbox row con deep_link a EditRuleSheet pre-loaded.';
