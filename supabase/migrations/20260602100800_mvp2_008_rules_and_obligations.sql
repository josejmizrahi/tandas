-- ============================================================================
-- MVP 2.0 — M.8 RULES + OBLIGATIONS
-- ============================================================================
-- obligations (adelantada de Money: es el target de las consecuencias de rules)
-- + rules + rule_evaluations + evaluator síncrono (D6) + enganche a check-in /
-- cancelación + RPCs: create_rule / evaluate_rules_for_event + RLS + smoke.
--
-- Reglas MVP cubiertas:
--   "Llegar tarde > 15 min → multa $100"        (trigger: event.checked_in)
--   "Cancelar el mismo día → multa $300"        (trigger: event.participation_cancelled)
--   condition_tree: {"op": ">", "field": "minutes_late", "value": 15}
--   consequences:   [{"type": "fine", "amount": 100, "currency": "MXN"}]
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. obligations (qué debe quién)
-- ────────────────────────────────────────────────────────────────────────────
create table public.obligations (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid references public.actors(id) on delete cascade,
  debtor_actor_id uuid not null references public.actors(id),
  creditor_actor_id uuid not null references public.actors(id),
  obligation_type text not null check (obligation_type in
    ('iou', 'fine', 'sanction', 'expense_share', 'loan', 'contribution', 'dues',
     'trip_share', 'game_debt', 'reservation_fee', 'other')),
  amount numeric,
  currency text,
  status text not null default 'open' check (status in
    ('open', 'settled', 'forgiven', 'disputed', 'cancelled')),
  due_at timestamptz,
  source_decision_id uuid references public.decisions(id),
  source_event_id uuid references public.calendar_events(id),
  source_reservation_id uuid references public.resource_reservations(id),
  source_rule_id uuid,
  metadata jsonb not null default '{}',
  client_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_obligations_debtor on public.obligations (debtor_actor_id, status);
create index idx_obligations_creditor on public.obligations (creditor_actor_id, status);
create index idx_obligations_context on public.obligations (context_actor_id, status);
create unique index idx_obligations_client_id on public.obligations (debtor_actor_id, client_id) where client_id is not null;

create trigger trg_obligations_touch before update on public.obligations
  for each row execute function public.touch_updated_at();

comment on table public.obligations is 'MVP2: qué debe quién (deuda actor→actor con contexto opcional).';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. rules + rule_evaluations
-- ────────────────────────────────────────────────────────────────────────────
create table public.rules (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  title text not null,
  body text,
  rule_type text not null default 'norm' check (rule_type in ('norm', 'automation', 'policy')),
  severity int not null default 1,
  status text not null default 'active' check (status in ('active', 'paused', 'archived')),
  trigger_event_type text,
  condition_tree jsonb,
  consequences jsonb,
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create index idx_rules_context on public.rules (context_actor_id, status);
create index idx_rules_trigger on public.rules (trigger_event_type) where status = 'active';

create trigger trg_rules_touch before update on public.rules
  for each row execute function public.touch_updated_at();

create table public.rule_evaluations (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid references public.rules(id) on delete set null,
  context_actor_id uuid,
  triggering_event_type text,
  triggering_object_type text,
  triggering_object_id uuid,
  outcome text not null check (outcome in ('matched', 'not_matched', 'error')),
  consequences_emitted jsonb not null default '{}',
  evaluated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'
);

create index idx_rule_evals_rule on public.rule_evaluations (rule_id, evaluated_at desc);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Evaluator (D6): condición simple sobre un payload jsonb
-- ────────────────────────────────────────────────────────────────────────────
-- condition_tree:
--   {"op": ">", "field": "minutes_late", "value": 15}
--   {"op": "=", "field": "same_day", "value": true}
--   {"op": "and", "conditions": [ ... ]}
--   null/missing → siempre matchea
create or replace function public._eval_condition(p_condition jsonb, p_payload jsonb)
returns boolean
language plpgsql immutable
as $$
declare
  v_op text;
  v_field text;
  v_expected jsonb;
  v_actual jsonb;
  v_sub jsonb;
  v_result boolean;
begin
  if p_condition is null or p_condition = 'null'::jsonb or p_condition = '{}'::jsonb then
    return true;
  end if;

  v_op := lower(p_condition->>'op');

  if v_op = 'and' then
    for v_sub in select * from jsonb_array_elements(p_condition->'conditions') loop
      if not public._eval_condition(v_sub, p_payload) then return false; end if;
    end loop;
    return true;
  elsif v_op = 'or' then
    for v_sub in select * from jsonb_array_elements(p_condition->'conditions') loop
      if public._eval_condition(v_sub, p_payload) then return true; end if;
    end loop;
    return false;
  end if;

  v_field := p_condition->>'field';
  v_expected := p_condition->'value';
  v_actual := p_payload->v_field;

  if v_actual is null then return false; end if;

  v_result := case v_op
    when '>'  then (v_actual::text)::numeric > (v_expected::text)::numeric
    when '>=' then (v_actual::text)::numeric >= (v_expected::text)::numeric
    when '<'  then (v_actual::text)::numeric < (v_expected::text)::numeric
    when '<=' then (v_actual::text)::numeric <= (v_expected::text)::numeric
    when '='  then v_actual = v_expected
    when '!=' then v_actual <> v_expected
    else false
  end;

  return coalesce(v_result, false);
exception when others then
  return false;
end; $$;

-- evaluate_rules_for_event: corre las reglas activas del contexto cuyo trigger
-- coincide, evalúa condiciones contra el payload, y ejecuta consecuencias.
-- p_subject_actor_id = el actor al que aplican las consecuencias (ej. quien llegó tarde).
create or replace function public.evaluate_rules_for_event(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_rule record;
  v_matched integer := 0;
  v_obligations jsonb := '[]'::jsonb;
  v_consequence jsonb;
  v_obligation_id uuid;
  v_eval_id uuid;
begin
  for v_rule in
    select * from public.rules
    where context_actor_id = p_context_actor_id
      and status = 'active'
      and trigger_event_type = p_trigger_event_type
  loop
    if public._eval_condition(v_rule.condition_tree, p_payload) then
      v_matched := v_matched + 1;

      -- ejecutar consecuencias
      for v_consequence in select * from jsonb_array_elements(coalesce(v_rule.consequences, '[]'::jsonb)) loop
        if v_consequence->>'type' in ('fine', 'create_obligation') then
          insert into public.obligations
            (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_type,
             amount, currency, source_event_id, source_rule_id, metadata)
          values
            (p_context_actor_id,
             p_subject_actor_id,
             p_context_actor_id,  -- creditor = el contexto
             coalesce(v_consequence->>'obligation_type', 'fine'),
             (v_consequence->>'amount')::numeric,
             coalesce(v_consequence->>'currency', 'MXN'),
             p_source_event_id,
             v_rule.id,
             jsonb_build_object('rule_title', v_rule.title, 'trigger', p_trigger_event_type))
          returning id into v_obligation_id;

          v_obligations := v_obligations || jsonb_build_object(
            'obligation_id', v_obligation_id,
            'rule_id', v_rule.id,
            'amount', (v_consequence->>'amount')::numeric);

          perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'obligation.created',
            'obligation', v_obligation_id,
            jsonb_build_object('rule_title', v_rule.title, 'amount', (v_consequence->>'amount')::numeric,
                               'obligation_type', coalesce(v_consequence->>'obligation_type', 'fine')),
            p_obligation_id := v_obligation_id);
        end if;
      end loop;

      insert into public.rule_evaluations
        (rule_id, context_actor_id, triggering_event_type, triggering_object_id, outcome, consequences_emitted)
      values
        (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, 'matched',
         jsonb_build_object('obligations', v_obligations));
    else
      insert into public.rule_evaluations
        (rule_id, context_actor_id, triggering_event_type, triggering_object_id, outcome)
      values
        (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, 'not_matched');
    end if;
  end loop;

  return jsonb_build_object('rules_matched', v_matched, 'obligations_created', v_obligations);
end; $$;

revoke all on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) from public, anon;
grant execute on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) to authenticated, service_role;

revoke all on function public._eval_condition(jsonb, jsonb) from public, anon, authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. create_rule
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.create_rule(
  p_context_actor_id uuid,
  p_title text,
  p_trigger_event_type text default null,
  p_condition_tree jsonb default null,
  p_consequences jsonb default null,
  p_body text default null,
  p_rule_type text default 'automation',
  p_severity int default 1
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to create rules in context %', p_context_actor_id using errcode = '42501';
  end if;

  insert into public.rules
    (context_actor_id, title, body, rule_type, severity, trigger_event_type,
     condition_tree, consequences, created_by_actor_id)
  values
    (p_context_actor_id, btrim(p_title), p_body, p_rule_type, p_severity, p_trigger_event_type,
     p_condition_tree, p_consequences, v_caller)
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'rule.created', 'rule', v_id,
    jsonb_build_object('title', btrim(p_title), 'trigger_event_type', p_trigger_event_type));

  return jsonb_build_object('rule_id', v_id,
    'rule', (select to_jsonb(r) from public.rules r where r.id = v_id));
end; $$;

revoke all on function public.create_rule(uuid, text, text, jsonb, jsonb, text, text, int) from public, anon;
grant execute on function public.create_rule(uuid, text, text, jsonb, jsonb, text, text, int) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Enganche del evaluator a los flujos de calendario (re-create de M.5 RPCs)
-- ────────────────────────────────────────────────────────────────────────────
-- check_in_participant ahora evalúa reglas con trigger 'event.checked_in'
create or replace function public.check_in_participant(
  p_event_id uuid,
  p_participant_actor_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_target uuid := coalesce(p_participant_actor_id, public.current_actor_id());
  v_event public.calendar_events%rowtype;
  v_pid uuid;
  v_minutes_late numeric;
  v_status text;
  v_rules jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  if v_target <> v_caller
     and not public.has_actor_authority(v_event.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to check in others' using errcode = '42501';
  end if;
  if v_target = v_caller and not public.is_context_member(v_event.context_actor_id) then
    raise exception 'not a member of event context' using errcode = '42501';
  end if;

  v_minutes_late := greatest(0, extract(epoch from (now() - v_event.starts_at)) / 60.0);
  v_status := case when v_minutes_late > 15 then 'late' else 'attended' end;

  insert into public.event_participants (event_id, participant_actor_id, status, checked_in_at)
  values (p_event_id, v_target, v_status, now())
  on conflict (event_id, participant_actor_id)
  do update set status = excluded.status, checked_in_at = now()
  returning id into v_pid;

  update public.event_participants
     set metadata = metadata || jsonb_build_object('minutes_late', round(v_minutes_late, 1))
   where id = v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_target, 'event.checked_in', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'minutes_late', round(v_minutes_late, 1), 'status', v_status));

  -- M.8: rule engine síncrono
  v_rules := public.evaluate_rules_for_event(
    v_event.context_actor_id, 'event.checked_in', v_target,
    jsonb_build_object('minutes_late', round(v_minutes_late, 1), 'status', v_status),
    p_event_id);

  return jsonb_build_object('participant_id', v_pid, 'status', v_status,
    'minutes_late', round(v_minutes_late, 1), 'rules', v_rules);
end; $$;

-- cancel_participation ahora evalúa reglas con trigger 'event.participation_cancelled'
create or replace function public.cancel_participation(p_event_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_event public.calendar_events%rowtype;
  v_pid uuid;
  v_same_day boolean;
  v_rules jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_event from public.calendar_events where id = p_event_id;
  if v_event.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;

  v_same_day := v_event.starts_at is not null and v_event.starts_at::date = now()::date;

  insert into public.event_participants (event_id, participant_actor_id, status, cancelled_at)
  values (p_event_id, v_caller, 'cancelled', now())
  on conflict (event_id, participant_actor_id)
  do update set status = 'cancelled', cancelled_at = now()
  returning id into v_pid;

  update public.event_participants
     set metadata = metadata || jsonb_build_object('same_day_cancellation', v_same_day)
   where id = v_pid;

  perform public._emit_activity(v_event.context_actor_id, v_caller, 'event.participation_cancelled', 'event_participant', v_pid,
    jsonb_build_object('event_id', p_event_id, 'same_day', v_same_day));

  -- M.8: rule engine síncrono
  v_rules := public.evaluate_rules_for_event(
    v_event.context_actor_id, 'event.participation_cancelled', v_caller,
    jsonb_build_object('same_day', v_same_day),
    p_event_id);

  return jsonb_build_object('participant_id', v_pid, 'same_day_cancellation', v_same_day, 'rules', v_rules);
end; $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table public.obligations enable row level security;
alter table public.rules enable row level security;
alter table public.rule_evaluations enable row level security;

create policy obligations_select on public.obligations
  for select to authenticated
  using (
    debtor_actor_id = public.current_actor_id()
    or creditor_actor_id = public.current_actor_id()
    or (context_actor_id is not null and public.is_context_member(context_actor_id))
  );

create policy rules_select on public.rules
  for select to authenticated
  using (public.is_context_member(context_actor_id));

create policy rule_evals_select on public.rule_evaluations
  for select to authenticated
  using (context_actor_id is not null and public.is_context_member(context_actor_id));

revoke all on public.obligations, public.rules, public.rule_evaluations from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m8_rules()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_ctx uuid;
  v_result jsonb; v_event uuid; v_code text;
  v_fine numeric;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M8A', '+520000000017', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M8B', '+520000000018', null);

  -- Setup: contexto con regla "tarde > 15 min → multa $100" y "cancelar same-day → multa $300"
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m8 Cena', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  perform public.create_rule(
    v_ctx::uuid, '_smoke_m8 Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);
  perform public.create_rule(
    v_ctx::uuid, '_smoke_m8 Multa por cancelar same-day',
    p_trigger_event_type := 'event.participation_cancelled',
    p_condition_tree := '{"op": "=", "field": "same_day", "value": true}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 300, "currency": "MXN"}]'::jsonb);

  -- Caso 1: member NO puede crear reglas
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  declare v_caught boolean := false;
  begin
    begin
      perform public.create_rule(v_ctx::uuid, '_smoke_m8 hack', p_trigger_event_type := 'x');
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m8 Caso1: member creó regla sin autoridad'; end if;
  end;

  -- Caso 2: evento que ya empezó hace 30 min + check-in tarde → multa $100 automática
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_event := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena', 'dinner',
    p_starts_at := now() - interval '30 minutes'))->>'event_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'mvp2_m8 Caso2: regla de tarde no matcheó';
  end if;

  select amount into v_fine from public.obligations
   where debtor_actor_id = v_b and creditor_actor_id = v_ctx::uuid
     and obligation_type = 'fine' and source_event_id = v_event::uuid
     and source_rule_id is not null;
  if v_fine is distinct from 100 then
    raise exception 'mvp2_m8 Caso2: multa incorrecta (% en vez de 100)', v_fine;
  end if;

  -- Caso 3: check-in a tiempo NO genera multa
  declare
    v_event2 uuid; v_obligations_before integer; v_obligations_after integer;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_event2 := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena 2', 'dinner',
      p_starts_at := now() + interval '5 minutes'))->>'event_id';
    select count(*) into v_obligations_before from public.obligations where debtor_actor_id = v_a;
    v_result := public.check_in_participant(v_event2::uuid);
    select count(*) into v_obligations_after from public.obligations where debtor_actor_id = v_a;
    if v_obligations_after <> v_obligations_before then
      raise exception 'mvp2_m8 Caso3: multa generada sin llegar tarde';
    end if;
  end;

  -- Caso 4: cancelar same-day → multa $300
  declare v_event3 uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    v_event3 := (public.create_calendar_event(v_ctx::uuid, '_smoke_m8 Cena Hoy', 'dinner',
      p_starts_at := now() + interval '4 hours'))->>'event_id';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_result := public.cancel_participation(v_event3::uuid);
    if (v_result->'rules'->>'rules_matched')::integer < 1 then
      raise exception 'mvp2_m8 Caso4: regla de cancelación no matcheó';
    end if;
    if not exists (
      select 1 from public.obligations
      where debtor_actor_id = v_b and amount = 300 and source_event_id = v_event3::uuid
    ) then
      raise exception 'mvp2_m8 Caso4: multa de cancelación no creada';
    end if;
  end;

  -- Caso 5: rule_evaluations registradas (matched y not_matched)
  if not exists (select 1 from public.rule_evaluations where context_actor_id = v_ctx::uuid and outcome = 'matched') then
    raise exception 'mvp2_m8 Caso5: evaluaciones matched no registradas';
  end if;
  if not exists (select 1 from public.rule_evaluations where context_actor_id = v_ctx::uuid and outcome = 'not_matched') then
    raise exception 'mvp2_m8 Caso5: evaluaciones not_matched no registradas';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.rule_evaluations where context_actor_id = v_ctx::uuid;
  delete from public.obligations where context_actor_id = v_ctx::uuid;
  delete from public.rules where context_actor_id = v_ctx::uuid;
  delete from public.event_participants where event_id in (select id from public.calendar_events where context_actor_id = v_ctx::uuid);
  delete from public.calendar_events where context_actor_id = v_ctx::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b);
  delete from public.actors where id in (v_a, v_b);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_mvp2_m8_rules passed (5 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m8_rules() from public, anon, authenticated;

comment on function public._smoke_mvp2_m8_rules() is 'Smoke MVP2 M.8: reglas, evaluator, multas automáticas por tarde/cancelación, obligations.';
