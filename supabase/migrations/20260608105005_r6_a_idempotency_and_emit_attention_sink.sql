-- R.6.A — Rule Engine 2.0: idempotency_key on rule_evaluations
--                          + rule_attention_items table
--                          + _r6_emit_attention sink
--                          + attention_inbox extension
--                          + evaluate_rules_for_event refactor
--
-- Founder firmó Q7 (2026-06-07): aplicar R.6.A solo como quick win porque
-- cierra el loop con R.5Y.A2 AttentionDispatcher ya shipped.
--
-- Comportamiento existente preservado: 'fine' / 'create_obligation' sinks intactos.
-- Idempotency aplica al nuevo code path; historical rule_evaluations rows
-- mantienen idempotency_key NULL (UNIQUE permite múltiples NULLs en PG default).
--
-- Gotchas resueltos durante shipping (2026-06-08):
-- 1. `digest()` vive en schema `extensions`, no `public`. Qualify como `extensions.digest()`.
-- 2. `ON CONFLICT (col)` no puede targetar índice UNIQUE parcial sin predicate explícito.
--    Solución: UNIQUE index NO parcial. PG default permite múltiples NULLs, así que
--    rows históricas con `idempotency_key IS NULL` no conflictan.

-- 1. rule_evaluations.idempotency_key.
alter table public.rule_evaluations
  add column if not exists idempotency_key text;

create unique index if not exists uniq_rule_evaluations_idempotency_key
  on public.rule_evaluations(idempotency_key);

-- 2. Idempotency helper (sha1, sin pgcrypto schema search).
create or replace function public._r6_compute_idempotency_key(
  p_rule_id uuid,
  p_source_event_id uuid,
  p_subject_actor_id uuid,
  p_consequence_index int
) returns text
language sql
immutable
as $$
  select encode(
    extensions.digest(
      coalesce(p_rule_id::text, '') || '|' ||
      coalesce(p_source_event_id::text, '') || '|' ||
      coalesce(p_subject_actor_id::text, '') || '|' ||
      coalesce(p_consequence_index::text, ''),
      'sha1'
    ),
    'hex'
  )
$$;

-- 3. rule_attention_items — target table del sink emit_attention.
create table if not exists public.rule_attention_items (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  subject_actor_id uuid not null references public.actors(id) on delete cascade,
  kind text not null,
  title text not null,
  reason text,
  priority text not null default 'normal'
    check (priority in ('critical','high','normal','low')),
  cta_action_key text not null,
  cta_scope_kind text not null,
  cta_scope_id uuid not null,
  resource_id uuid references public.resources(id) on delete set null,
  status text not null default 'open'
    check (status in ('open','resolved','dismissed')),
  source_rule_id uuid references public.rules(id) on delete cascade,
  source_event_id uuid,
  idempotency_key text unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists idx_rule_attention_items_subject_open
  on public.rule_attention_items(subject_actor_id)
  where status = 'open';

create index if not exists idx_rule_attention_items_context
  on public.rule_attention_items(context_actor_id);

create index if not exists idx_rule_attention_items_source_rule
  on public.rule_attention_items(source_rule_id);

-- 4. RLS — solo subject lee sus attention items.
alter table public.rule_attention_items enable row level security;

drop policy if exists "rule_attention_items_select_subject" on public.rule_attention_items;
create policy "rule_attention_items_select_subject"
  on public.rule_attention_items
  for select
  using (subject_actor_id = public.current_actor_id());

-- Write/update vía RPCs SECURITY DEFINER (sin policy WRITE = denied default).

-- 5. _r6_emit_attention sink. Idempotente via idempotency_key UNIQUE.
create or replace function public._r6_emit_attention(
  p_context_actor_id uuid,
  p_subject_actor_id uuid,
  p_consequence jsonb,
  p_rule_id uuid,
  p_source_event_id uuid,
  p_idempotency_key text
) returns uuid
language plpgsql
security definer
set search_path to public, auth
as $$
declare
  v_id uuid;
begin
  insert into public.rule_attention_items
    (context_actor_id, subject_actor_id,
     kind, title, reason, priority,
     cta_action_key, cta_scope_kind, cta_scope_id,
     resource_id,
     source_rule_id, source_event_id, idempotency_key, metadata)
  values
    (p_context_actor_id, p_subject_actor_id,
     coalesce(p_consequence->>'kind', 'rule_violation'),
     coalesce(p_consequence->>'title', 'Atención requerida'),
     p_consequence->>'reason',
     coalesce(p_consequence->>'priority', 'normal'),
     coalesce(p_consequence->>'cta_action_key', 'view_rule'),
     coalesce(p_consequence->>'cta_scope_kind', 'rule'),
     coalesce(nullif(p_consequence->>'cta_scope_id','')::uuid, p_rule_id),
     nullif(p_consequence->>'resource_id','')::uuid,
     p_rule_id,
     p_source_event_id,
     p_idempotency_key,
     coalesce(p_consequence->'metadata', '{}'::jsonb))
  on conflict (idempotency_key) do nothing
  returning id into v_id;

  return v_id;
end;
$$;

-- 6. attention_inbox() — extender con UNION rule_attention_items.
create or replace function public.attention_inbox()
returns jsonb
language plpgsql
stable
security definer
set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_items jsonb := '[]'::jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  -- reservation_conflict (legacy)
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'reservation_conflict',
      'subject_id', c.id,
      'context_actor_id', r.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = r.context_actor_id),
      'title', 'Conflicto de reservación',
      'reason', 'Hay reservaciones que se solapan en un recurso donde participas',
      'cta_action_key', 'resolve_conflict',
      'cta_scope_kind', 'reservation',
      'cta_scope_id', r.id,
      'resource_id', r.resource_id,
      'occurred_at', c.created_at
    ))
    from public.reservation_conflicts c
    join public.resource_reservations r
      on r.id = c.reservation_a_id or r.id = c.reservation_b_id
    where c.resolution_status = 'open'
      and (r.requested_by_actor_id = v_caller or r.reserved_for_actor_id = v_caller)
  ), '[]'::jsonb);

  -- decision_vote
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'decision_vote',
      'subject_id', d.id,
      'context_actor_id', d.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = d.context_actor_id),
      'title', d.title,
      'reason', 'Decisión abierta donde puedes votar',
      'cta_action_key', 'vote',
      'cta_scope_kind', 'decision',
      'cta_scope_id', d.id,
      'occurred_at', d.created_at
    ))
    from public.decisions d
    where d.status = 'open'
      and public.has_actor_authority(d.context_actor_id, v_caller, 'decisions.vote')
      and not exists (
        select 1 from public.decision_votes dv
        where dv.decision_id = d.id and dv.voter_actor_id = v_caller
      )
  ), '[]'::jsonb);

  -- obligation_pay / obligation_complete
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', case when o.obligation_kind = 'money' then 'obligation_pay' else 'obligation_complete' end,
      'subject_id', o.id,
      'context_actor_id', o.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = o.context_actor_id),
      'title', coalesce(o.title, 'Compromiso pendiente'),
      'reason', case when o.obligation_kind = 'money' then 'Tienes un pago pendiente'
                     else 'Tienes un compromiso pendiente' end,
      'cta_action_key', case when o.obligation_kind = 'money' then 'pay' else 'mark_completed' end,
      'cta_scope_kind', 'obligation',
      'cta_scope_id', o.id,
      'occurred_at', o.created_at
    ))
    from public.obligations o
    where o.status = 'open' and o.debtor_actor_id = v_caller
  ), '[]'::jsonb);

  -- invitation
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'invitation',
      'subject_id', m.id,
      'context_actor_id', m.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = m.context_actor_id),
      'title', 'Invitación pendiente',
      'reason', 'Te invitaron a un contexto',
      'cta_action_key', 'accept_invitation',
      'cta_scope_kind', 'context',
      'cta_scope_id', m.context_actor_id,
      'occurred_at', m.created_at
    ))
    from public.actor_memberships m
    where m.member_actor_id = v_caller and m.membership_status = 'invited'
  ), '[]'::jsonb);

  -- settlement_open
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'settlement_open',
      'subject_id', si.id,
      'context_actor_id', sb.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = sb.context_actor_id),
      'title', 'Pago pendiente de liquidación',
      'reason', format('Debes %s %s a %s',
        si.amount, si.currency,
        (select display_name from public.actors where id = si.to_actor_id)
      ),
      'amount', si.amount,
      'currency', si.currency,
      'counterparty_name', (select display_name from public.actors where id = si.to_actor_id),
      'cta_action_key', 'mark_paid',
      'cta_scope_kind', 'settlement_item',
      'cta_scope_id', si.id,
      'occurred_at', sb.created_at
    ))
    from public.settlement_items si
    join public.settlement_batches sb on sb.id = si.settlement_batch_id
    where si.from_actor_id = v_caller
      and si.status not in ('paid', 'cancelled', 'voided')
      and sb.status not in ('finalized', 'cancelled')
  ), '[]'::jsonb);

  -- resource_conflict_direct
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', 'resource_conflict_direct',
      'subject_id', rc.id,
      'context_actor_id', rc.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = rc.context_actor_id),
      'title', coalesce(
        (select display_name from public.resources where id = rc.resource_id), 'Recurso'
      ) || ': conflicto',
      'reason', case rc.severity
        when 'critical' then 'Conflicto crítico en un recurso del contexto'
        when 'warning'  then 'Conflicto en un recurso del contexto'
        else 'Hay un conflicto que requiere revisión'
      end,
      'cta_action_key', 'resolve_resource_conflict',
      'cta_scope_kind', 'resource',
      'cta_scope_id', rc.resource_id,
      'resource_id', rc.resource_id,
      'occurred_at', rc.detected_at
    ))
    from public.resource_conflicts rc
    where rc.status = 'open'
      and coalesce(rc.source_type, '') != 'reservation_conflict'
      and exists (
        select 1 from public.actor_memberships m
        where m.context_actor_id = rc.context_actor_id
          and m.member_actor_id = v_caller
          and m.membership_status = 'active'
      )
  ), '[]'::jsonb);

  -- R.6.A NEW: rule-emitted attention items
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', rai.kind,
      'subject_id', rai.id,
      'context_actor_id', rai.context_actor_id,
      'context_display_name', (select display_name from public.actors where id = rai.context_actor_id),
      'title', rai.title,
      'reason', coalesce(rai.reason, ''),
      'cta_action_key', rai.cta_action_key,
      'cta_scope_kind', rai.cta_scope_kind,
      'cta_scope_id', rai.cta_scope_id,
      'resource_id', rai.resource_id,
      'occurred_at', rai.created_at
    ))
    from public.rule_attention_items rai
    where rai.subject_actor_id = v_caller
      and rai.status = 'open'
  ), '[]'::jsonb);

  return coalesce((
    select jsonb_agg(item)
    from (
      select item
      from jsonb_array_elements(v_items) item
      order by (item->>'occurred_at')::timestamptz desc nulls last
      limit 5
    ) sorted
  ), '[]'::jsonb);
end;
$$;

-- 7. evaluate_rules_for_event — refactor para usar idempotency + dispatch emit_attention.
create or replace function public.evaluate_rules_for_event(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_rule record;
  v_matched integer := 0;
  v_obligations jsonb := '[]'::jsonb;
  v_attentions jsonb := '[]'::jsonb;
  v_rule_obligations jsonb;
  v_rule_attentions jsonb;
  v_consequence jsonb;
  v_consequence_index int;
  v_obligation_id uuid;
  v_attention_id uuid;
  v_eval_id uuid;
  v_outcome text;
  v_reason text;
  v_kind text;
  v_title text;
  v_obligation_type text;
  v_existing uuid;
  v_is_new boolean;
  v_idempotency_key text;
begin
  if v_caller is not null
     and v_caller <> p_subject_actor_id
     and not exists (
       select 1 from public.calendar_events e
       where e.id = p_source_event_id and e.host_actor_id = v_caller)
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to evaluate rules for other actors' using errcode = '42501';
  end if;

  for v_rule in
    select * from public.rules
    where context_actor_id = p_context_actor_id
      and status = 'active'
      and trigger_event_type = p_trigger_event_type
      and public._rule_target_matches(coalesce(target_filter, '{}'::jsonb), p_payload)
  loop
    v_outcome := case when public._eval_condition(v_rule.condition_tree, p_payload)
                      then 'matched' else 'not_matched' end;
    v_rule_obligations := '[]'::jsonb;
    v_rule_attentions := '[]'::jsonb;

    -- Idempotency para la evaluation row (consequence_index = -1).
    v_idempotency_key := public._r6_compute_idempotency_key(
      v_rule.id, p_source_event_id, p_subject_actor_id, -1
    );

    insert into public.rule_evaluations
      (rule_id, context_actor_id, triggering_event_type, triggering_object_id,
       outcome, metadata, idempotency_key)
    values
      (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, v_outcome,
       jsonb_build_object('subject_actor_id', p_subject_actor_id, 'payload', p_payload),
       v_idempotency_key)
    on conflict (idempotency_key) do nothing
    returning id into v_eval_id;

    -- Si fue duplicate, recuperar el id existente y SKIP consequences (ya emitidas).
    if v_eval_id is null then
      select id into v_eval_id from public.rule_evaluations
       where idempotency_key = v_idempotency_key
       limit 1;
      continue;
    end if;

    if v_outcome = 'matched' then
      v_matched := v_matched + 1;
      v_consequence_index := 0;

      for v_consequence in select * from jsonb_array_elements(coalesce(v_rule.consequences, '[]'::jsonb)) loop
        if v_consequence->>'type' in ('fine', 'create_obligation') then
          v_kind := coalesce(v_consequence->>'kind', 'money');
          v_title := coalesce(v_consequence->>'title', v_rule.title);
          v_reason := coalesce(v_consequence->>'reason', v_consequence->>'title', v_rule.title);

          select id into v_existing from public.obligations
           where source_rule_id = v_rule.id
             and source_event_id is not distinct from p_source_event_id
             and debtor_actor_id = p_subject_actor_id
             and metadata->>'reason' is not distinct from v_reason
             and status <> 'cancelled'
           limit 1;

          v_is_new := v_existing is null;
          if v_is_new then
            if v_kind = 'money' then
              v_obligation_type := coalesce(v_consequence->>'obligation_type', 'fine');
              insert into public.obligations
                (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_kind, obligation_type,
                 amount, currency, source_event_id, source_rule_id, metadata)
              values
                (p_context_actor_id, p_subject_actor_id, p_context_actor_id, 'money', v_obligation_type,
                 (v_consequence->>'amount')::numeric, coalesce(v_consequence->>'currency', 'MXN'),
                 p_source_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope))
              returning id into v_obligation_id;
            else
              v_obligation_type := coalesce(v_consequence->>'obligation_type', 'other');
              insert into public.obligations
                (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_kind, obligation_type,
                 title, description, due_at, source_event_id, source_rule_id, metadata)
              values
                (p_context_actor_id, p_subject_actor_id, p_context_actor_id, v_kind, v_obligation_type,
                 v_title, v_consequence->>'description',
                 nullif(v_consequence->>'due_at', '')::timestamptz,
                 p_source_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope))
              returning id into v_obligation_id;
            end if;

            perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'obligation.created',
              'obligation', v_obligation_id,
              jsonb_build_object('rule_title', v_rule.title, 'kind', v_kind, 'title', v_title,
                                 'amount', (v_consequence->>'amount')::numeric,
                                 'obligation_type', v_obligation_type, 'reason', v_reason,
                                 'system', true, 'triggered_by_event_type', p_trigger_event_type,
                                 'source_rule_id', v_rule.id),
              p_obligation_id := v_obligation_id);

            if v_kind = 'money' and v_obligation_type = 'fine' then
              perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'fine.created',
                'obligation', v_obligation_id,
                jsonb_build_object('rule_title', v_rule.title, 'amount', (v_consequence->>'amount')::numeric,
                                   'reason', v_reason,
                                   'system', true, 'triggered_by_event_type', p_trigger_event_type,
                                   'source_rule_id', v_rule.id),
                p_obligation_id := v_obligation_id);
            end if;
          else
            v_obligation_id := v_existing;
          end if;

          v_rule_obligations := v_rule_obligations || jsonb_build_object(
            'obligation_id', v_obligation_id, 'rule_id', v_rule.id, 'kind', v_kind,
            'amount', (v_consequence->>'amount')::numeric, 'already_existed', not v_is_new);

        elsif v_consequence->>'type' = 'emit_attention' then
          -- R.6.A nuevo sink. Idempotente via idempotency_key per-consequence.
          v_attention_id := public._r6_emit_attention(
            p_context_actor_id := p_context_actor_id,
            p_subject_actor_id := p_subject_actor_id,
            p_consequence := v_consequence,
            p_rule_id := v_rule.id,
            p_source_event_id := p_source_event_id,
            p_idempotency_key := public._r6_compute_idempotency_key(
              v_rule.id, p_source_event_id, p_subject_actor_id, v_consequence_index
            )
          );
          v_rule_attentions := v_rule_attentions || jsonb_build_object(
            'attention_id', v_attention_id,
            'kind', coalesce(v_consequence->>'kind', 'rule_violation'),
            'rule_id', v_rule.id,
            'already_existed', v_attention_id is null
          );
        end if;

        v_consequence_index := v_consequence_index + 1;
      end loop;

      update public.rule_evaluations
         set consequences_emitted = jsonb_build_object(
           'obligations', v_rule_obligations,
           'attentions',  v_rule_attentions
         )
       where id = v_eval_id;

      v_obligations := v_obligations || v_rule_obligations;
      v_attentions := v_attentions || v_rule_attentions;
    end if;

    perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'rule.evaluated',
      'rule_evaluation', v_eval_id,
      jsonb_build_object('rule_id', v_rule.id, 'rule_title', v_rule.title, 'outcome', v_outcome,
                         'triggered_by_event_type', p_trigger_event_type, 'source_rule_id', v_rule.id));
  end loop;

  return jsonb_build_object(
    'rules_matched', v_matched,
    'obligations_created', v_obligations,
    'attentions_emitted', v_attentions
  );
end;
$$;
