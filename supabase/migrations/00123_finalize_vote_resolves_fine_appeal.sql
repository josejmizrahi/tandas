-- 00123 — finalize_vote v4: resuelve la multa cuando un fine_appeal cierra.
--
-- Background:
-- ===========
-- v3 (00032) extendió finalize_vote para emitir ruleChangeApplyPending
-- cuando vote_type='rule_change' pasaba. Para vote_type='fine_appeal',
-- finalize_vote nunca tocó fines.status — la multa apelada se quedaba
-- pegada en 'in_appeal' indefinidamente, incluso cuando el grupo votaba
-- a favor del apelante. Auditoría 2026-05-12 lo marcó como blocker.
--
-- start_fine_appeal (00052) flipea fines.status: officialized → in_appeal.
-- Sin v4, no había contraparte para devolver la multa a un estado final.
--
-- Semántica:
--   - passed         → fines.status='voided', waived=true (la apelación
--                      ganó: la comunidad anuló la multa).
--   - failed         → fines.status='officialized' (regresa al estado
--                      previo al appeal: la multa sigue oficial).
--   - quorum_failed  → fines.status='officialized' (mismo que failed —
--                      sin quorum no hay revocación).
--
-- Idempotencia:
--   - El UPDATE de fines lleva guard `WHERE status='in_appeal'`. Una
--     multa que llegó al vote sin pasar por start_fine_appeal (e.g.
--     start_vote directo, como appealQuorumFailed.test.ts) no fue
--     flipada a in_appeal, así que el UPDATE no la toca. La multa
--     queda en su estado original.
--   - Si finalize_vote corre dos veces para el mismo vote, la segunda
--     pasada retorna temprano por el guard `v_vote.status <> 'open'`
--     existente en v3.
--
-- Sistema de eventos:
--   - Emite appealResolved (ya whitelistado en 00117) con payload
--     {fine_id, resolution, new_fine_status} para que el rule engine,
--     activity feed e inbox cleaners reaccionen.
--   - El voteResolved que v3 ya emite se mantiene intacto.
--
-- V3 contracts intactos: rule_change + voteResolved + outbox fan-out
-- siguen igual. v4 sólo agrega el bloque final fine_appeal.

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
  -- v4 fine_appeal locals
  v_new_fine_status     text;
  v_fine_amount         int;
  v_fine_group_id       uuid;
  v_fine_user_id        uuid;
  v_fine_updated        int;
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

  -- V3 (00032): rule_change resuelto passed → user_action al founder + outbox push.
  if v_vote.vote_type = 'rule_change' and v_resolution = 'passed' then
    v_current_amount  := nullif(v_vote.payload->>'current_amount', '')::int;
    v_proposed_amount := nullif(v_vote.payload->>'proposed_amount', '')::int;

    if v_current_amount is null or v_proposed_amount is null then
      return v_resolution;
    end if;

    select gm.id, gm.user_id
      into v_founder_member_id, v_founder_user_id
      from public.group_members gm
     where gm.group_id = v_vote.group_id
       and gm.roles ?| array['founder']
       and gm.active = true
     order by gm.created_at asc
     limit 1;

    if v_founder_user_id is not null then
      v_rule_id := v_vote.reference_id;

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

  -- NUEVO V4: fine_appeal resuelto → mutar fines.status + emitir appealResolved.
  if v_vote.vote_type = 'fine_appeal' then
    -- Map resolution → target fine status. Only 'passed' revokes the fine;
    -- 'failed' and 'quorum_failed' restore it to officialized so the
    -- appellant sees a final state (no permanent 'in_appeal' limbo).
    v_new_fine_status := case
      when v_resolution = 'passed'         then 'voided'
      when v_resolution in ('failed', 'quorum_failed') then 'officialized'
      else null
    end;

    if v_new_fine_status is not null and v_vote.reference_id is not null then
      -- Guard: only flip fines that actually went through start_fine_appeal
      -- (status='in_appeal'). Fines that reached the vote via start_vote
      -- directly stay untouched — this preserves backwards compatibility
      -- with appealQuorumFailed.test.ts and any pre-00052 historic data.
      -- The PK match guarantees ≤1 row; RETURNING INTO populates the
      -- scalars iff a row was actually updated.
      update public.fines
         set status        = v_new_fine_status,
             waived        = (v_new_fine_status = 'voided'),
             waived_at     = case when v_new_fine_status = 'voided' then now() else waived_at end,
             waived_reason = case when v_new_fine_status = 'voided'
                                  then 'appeal_passed (vote ' || left(p_vote_id::text, 8) || ')'
                                  else waived_reason end,
             updated_at    = now()
       where id     = v_vote.reference_id
         and status = 'in_appeal'
       returning amount, group_id, user_id
         into v_fine_amount, v_fine_group_id, v_fine_user_id;

      get diagnostics v_fine_updated = row_count;

      -- Emit appealResolved iff we actually mutated a fine row. If the
      -- guard skipped (status wasn't in_appeal), we don't fabricate an
      -- appealResolved event for a fine that wasn't formally appealed.
      if coalesce(v_fine_updated, 0) > 0 then
        insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
        values (
          v_vote.group_id,
          'appealResolved',
          v_vote.reference_id,
          nullif(v_vote.payload->>'member_id', '')::uuid,
          jsonb_build_object(
            'vote_id',          p_vote_id,
            'fine_id',          v_vote.reference_id,
            'resolution',       v_resolution,
            'new_fine_status',  v_new_fine_status,
            'amount',           v_fine_amount
          )
        );

        -- Resolve any open finePending / appealVotePending UserActions for
        -- this fine so the infractor's inbox doesn't carry stale rows.
        -- finePending is keyed by reference_id = fine_id; appealVotePending
        -- by reference_id = vote_id. Both get cleared on appeal resolution.
        update public.user_actions
           set resolved_at = now()
         where reference_id = v_vote.reference_id
           and action_type  = 'finePending'
           and resolved_at  is null;

        update public.user_actions
           set resolved_at = now()
         where reference_id = p_vote_id
           and action_type  = 'appealVotePending'
           and resolved_at  is null;
      end if;
    end if;
  end if;

  return v_resolution;
end;
$$;

comment on function public.finalize_vote is
  'v4: resuelve fines.status para vote_type=fine_appeal (passed→voided, failed/quorum_failed→officialized). v3: rule_change passed → user_action ruleChangeApplyPending al founder + outbox row. v2: voteResolved system_event + outbox fan-out a voters + appellant.';
