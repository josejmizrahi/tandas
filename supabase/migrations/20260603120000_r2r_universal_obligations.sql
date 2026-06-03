-- ============================================================================
-- R.2R — UNIVERSAL OBLIGATIONS (compromisos monetarios y no monetarios)
-- ============================================================================
-- Doctrina (R.2P, founder-signed): Obligation = "algo que un actor debe a otro
-- actor", sea dinero o acción. NO se crea tabla `task`: una sola primitiva
-- universal cubre los dos ejes.
--
--   Eje monetario  (kind = 'money')   → amount/currency, se liquida (settled)
--   Eje de acción  (kind != 'money')  → title/description/due_at, se completa
--
-- Este migration:
--   1. Extiende obligations: obligation_kind + campos de completion + status nuevos.
--   2. evaluate_rules_for_event v5: las consecuencias pueden crear action
--      obligations (no solo multas) — { "type":"create_obligation",
--      "kind":"action", "title":"Traer botella de vino" }.
--   3. RPCs: create_action_obligation · complete_obligation · obligation_detail
--      · why_obligation_exists.
--   4. Smokes R.2R (money / action / approval / rule-generated / backward-compat).
--
-- Compatibilidad:
--   · obligation_kind default 'money' → todas las filas y RPCs de dinero
--     (record_expense/fine/game_result, settlement, novación R.2N) intactos.
--   · El motor de neteo (R.2N) filtra amount/currency not null → las action
--     obligations (amount/currency null) quedan fuera del settlement por diseño.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Schema: obligation_kind + completion + status lifecycle ampliado
-- ────────────────────────────────────────────────────────────────────────────
alter table public.obligations
  add column if not exists obligation_kind text not null default 'money';

alter table public.obligations
  drop constraint if exists obligations_kind_check;
alter table public.obligations
  add constraint obligations_kind_check check (obligation_kind in
    ('money', 'action', 'approval', 'delivery', 'attendance', 'document', 'reservation', 'custom'));

alter table public.obligations add column if not exists title text;
alter table public.obligations add column if not exists description text;
alter table public.obligations add column if not exists completion_notes text;
alter table public.obligations add column if not exists completed_at timestamptz;
alter table public.obligations add column if not exists completed_by_actor_id uuid references public.actors(id);
alter table public.obligations add column if not exists completion_metadata jsonb not null default '{}';

-- Status lifecycle: money usa open→settled; action usa open→(accepted→in_progress)→completed.
-- expired/cancelled/forgiven/disputed son comunes. Se reemplaza el CHECK original
-- (búsqueda robusta por definición: el inline check de la columna status).
do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
   where conrelid = 'public.obligations'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ilike '%status%' and pg_get_constraintdef(oid) ilike '%settled%'
   limit 1;
  if v_name is not null then
    execute format('alter table public.obligations drop constraint %I', v_name);
  end if;
end $$;

alter table public.obligations
  add constraint obligations_status_check check (status in
    ('open', 'accepted', 'in_progress', 'completed', 'expired',
     'settled', 'cancelled', 'forgiven', 'disputed'));

create index if not exists idx_obligations_kind on public.obligations (context_actor_id, obligation_kind, status);
create index if not exists idx_obligations_assignee on public.obligations (debtor_actor_id, obligation_kind, status);

comment on column public.obligations.obligation_kind is
  'R.2R: eje universal del compromiso. money = deuda (settled); el resto = acción (completed).';
comment on table public.obligations is
  'MVP2/R.2R: qué debe quién — primitiva universal de compromisos (dinero y acción), sin tabla task.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. evaluate_rules_for_event v5 — consecuencias money O action
-- ────────────────────────────────────────────────────────────────────────────
-- Reproduce v4 (R.2J-1) y agrega la rama de action obligation: una consecuencia
-- con "kind" != 'money' (o sin amount) crea una obligación de acción
-- (title/description/due_at, sin amount/currency). El resto (multas, dedup,
-- activity, rule_evaluations, gate R.2E) se conserva idéntico.
create or replace function public.evaluate_rules_for_event(
  p_context_actor_id uuid,
  p_trigger_event_type text,
  p_subject_actor_id uuid,
  p_payload jsonb,
  p_source_event_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_rule record;
  v_matched integer := 0;
  v_obligations jsonb := '[]'::jsonb;
  v_rule_obligations jsonb;
  v_consequence jsonb;
  v_obligation_id uuid;
  v_eval_id uuid;
  v_outcome text;
  v_reason text;
  v_kind text;
  v_title text;
  v_obligation_type text;
  v_existing uuid;
  v_is_new boolean;
begin
  -- R.2E gate: ejecución directa solo para self, host del evento, o rules.manage
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
  loop
    v_outcome := case when public._eval_condition(v_rule.condition_tree, p_payload)
                      then 'matched' else 'not_matched' end;
    v_rule_obligations := '[]'::jsonb;

    insert into public.rule_evaluations
      (rule_id, context_actor_id, triggering_event_type, triggering_object_id, outcome, metadata)
    values
      (v_rule.id, p_context_actor_id, p_trigger_event_type, p_source_event_id, v_outcome,
       jsonb_build_object('subject_actor_id', p_subject_actor_id, 'payload', p_payload))
    returning id into v_eval_id;

    if v_outcome = 'matched' then
      v_matched := v_matched + 1;

      for v_consequence in select * from jsonb_array_elements(coalesce(v_rule.consequences, '[]'::jsonb)) loop
        if v_consequence->>'type' in ('fine', 'create_obligation') then
          -- R.2R: kind determina money vs action. 'fine' y create_obligation sin
          -- kind explícito → money (compat con reglas existentes).
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
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type))
              returning id into v_obligation_id;
            else
              -- R.2R: action obligation generada por regla (sin dinero)
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
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type))
              returning id into v_obligation_id;
            end if;

            -- R.2J.6: consecuencias automáticas auditables — sistema + regla de origen
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
        end if;
      end loop;

      update public.rule_evaluations
         set consequences_emitted = jsonb_build_object('obligations', v_rule_obligations)
       where id = v_eval_id;

      v_obligations := v_obligations || v_rule_obligations;
    end if;

    -- R.2J.6: cada evaluación auditada con su regla y trigger de origen
    perform public._emit_activity(p_context_actor_id, p_subject_actor_id, 'rule.evaluated',
      'rule_evaluation', v_eval_id,
      jsonb_build_object('rule_id', v_rule.id, 'rule_title', v_rule.title, 'outcome', v_outcome,
                         'triggered_by_event_type', p_trigger_event_type, 'source_rule_id', v_rule.id));
  end loop;

  return jsonb_build_object('rules_matched', v_matched, 'obligations_created', v_obligations);
end; $$;

revoke all on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) from public, anon;
grant execute on function public.evaluate_rules_for_event(uuid, text, uuid, jsonb, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. create_action_obligation — crear un compromiso de acción (no monetario)
-- ────────────────────────────────────────────────────────────────────────────
-- p_debtor_actor_id = el responsable (assignee). creditor = contexto por defecto
-- (a quién le rinde: el contexto), o un actor específico (ej. aprobar contrato
-- "para" otro). Auto-asignarse no requiere autoridad; asignar a otro requiere
-- members.manage (igual que record_fine).
create or replace function public.create_action_obligation(
  p_context_actor_id uuid,
  p_debtor_actor_id uuid,
  p_title text,
  p_kind text default 'action',
  p_description text default null,
  p_due_at timestamptz default null,
  p_creditor_actor_id uuid default null,
  p_source_event_id uuid default null,
  p_source_reservation_id uuid default null,
  p_source_decision_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_creditor uuid := coalesce(p_creditor_actor_id, p_context_actor_id);
  v_ob uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;
  if p_kind = 'money' then
    raise exception 'create_action_obligation no crea obligaciones de dinero (usa record_expense/record_fine)' using errcode = '22023';
  end if;
  if p_kind not in ('action', 'approval', 'delivery', 'attendance', 'document', 'reservation', 'custom') then
    raise exception 'invalid obligation_kind: %', p_kind using errcode = '22023';
  end if;
  if coalesce(btrim(p_title), '') = '' then
    raise exception 'title is required for an action obligation' using errcode = '22023';
  end if;
  if p_debtor_actor_id <> v_caller
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'assigning obligations to others requires members.manage' using errcode = '42501';
  end if;

  insert into public.obligations
    (context_actor_id, debtor_actor_id, creditor_actor_id, obligation_kind, obligation_type,
     title, description, due_at, status,
     source_event_id, source_reservation_id, source_decision_id, metadata, client_id)
  values
    (p_context_actor_id, p_debtor_actor_id, v_creditor, p_kind, 'other',
     btrim(p_title), p_description, p_due_at, 'open',
     p_source_event_id, p_source_reservation_id, p_source_decision_id,
     coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('created_by', v_caller), p_client_id)
  returning id into v_ob;

  perform public._emit_activity(p_context_actor_id, v_caller, 'obligation.created', 'obligation', v_ob,
    jsonb_build_object('kind', p_kind, 'title', btrim(p_title), 'debtor', p_debtor_actor_id,
                       'due_at', p_due_at),
    p_obligation_id := v_ob);

  return jsonb_build_object('obligation_id', v_ob, 'kind', p_kind, 'status', 'open');
end; $$;

revoke all on function public.create_action_obligation(uuid, uuid, text, text, text, timestamptz, uuid, uuid, uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.create_action_obligation(uuid, uuid, text, text, text, timestamptz, uuid, uuid, uuid, uuid, jsonb, text) to authenticated, service_role;

comment on function public.create_action_obligation(uuid, uuid, text, text, text, timestamptz, uuid, uuid, uuid, uuid, jsonb, text) is
  'R.2R: crea un compromiso de acción (no monetario). El responsable es debtor; se completa con complete_obligation.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. complete_obligation — marcar un compromiso de acción como cumplido
-- ────────────────────────────────────────────────────────────────────────────
-- Lo completa el responsable (debtor), el acreedor/verificador (creditor) o un
-- manager (members.manage) — cubre el caso "aprobada/verificada por otro actor".
-- Las obligaciones de dinero NO se completan: se liquidan vía settlement.
create or replace function public.complete_obligation(
  p_obligation_id uuid,
  p_completion_notes text default null,
  p_completion_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_ob from public.obligations where id = p_obligation_id for update;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  if v_ob.obligation_kind = 'money' then
    raise exception 'money obligations are settled, not completed' using errcode = '22023';
  end if;

  -- Autoridad: responsable, acreedor/verificador, o manager del contexto
  if v_caller <> v_ob.debtor_actor_id
     and v_caller <> v_ob.creditor_actor_id
     and not (v_ob.context_actor_id is not null
              and public.has_actor_authority(v_ob.context_actor_id, v_caller, 'members.manage')) then
    raise exception 'not authorized to complete this obligation' using errcode = '42501';
  end if;

  -- Idempotente
  if v_ob.status = 'completed' then
    return jsonb_build_object('obligation_id', p_obligation_id, 'status', 'completed', 'already_completed', true);
  end if;
  if v_ob.status in ('cancelled', 'expired', 'forgiven', 'settled', 'disputed') then
    raise exception 'cannot complete an obligation in status %', v_ob.status using errcode = '22023';
  end if;

  update public.obligations
     set status = 'completed',
         completed_at = now(),
         completed_by_actor_id = v_caller,
         completion_notes = p_completion_notes,
         completion_metadata = coalesce(p_completion_metadata, '{}'::jsonb)
   where id = p_obligation_id;

  perform public._emit_activity(v_ob.context_actor_id, v_caller, 'obligation.completed', 'obligation', p_obligation_id,
    jsonb_build_object('kind', v_ob.obligation_kind, 'title', v_ob.title,
                       'completed_by', v_caller, 'debtor', v_ob.debtor_actor_id),
    p_obligation_id := p_obligation_id);

  return jsonb_build_object('obligation_id', p_obligation_id, 'status', 'completed',
    'completed_by', v_caller, 'completed_at', now());
end; $$;

revoke all on function public.complete_obligation(uuid, text, jsonb) from public, anon;
grant execute on function public.complete_obligation(uuid, text, jsonb) to authenticated, service_role;

comment on function public.complete_obligation(uuid, text, jsonb) is
  'R.2R: marca una obligación de acción como completed (responsable, verificador o manager). Las de dinero se liquidan, no se completan.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. obligation_detail — lectura de una obligación (cualquier kind)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.obligation_detail(p_obligation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  if v_caller <> v_ob.debtor_actor_id
     and v_caller <> v_ob.creditor_actor_id
     and not (v_ob.context_actor_id is not null and public.is_context_member(v_ob.context_actor_id)) then
    raise exception 'not authorized to view this obligation' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'id', v_ob.id,
    'context_actor_id', v_ob.context_actor_id,
    'kind', v_ob.obligation_kind,
    'obligation_type', v_ob.obligation_type,
    'status', v_ob.status,
    'title', v_ob.title,
    'description', v_ob.description,
    'amount', v_ob.amount,
    'currency', v_ob.currency,
    'due_at', v_ob.due_at,
    'debtor_actor_id', v_ob.debtor_actor_id,
    'creditor_actor_id', v_ob.creditor_actor_id,
    'completed_at', v_ob.completed_at,
    'completed_by_actor_id', v_ob.completed_by_actor_id,
    'completion_notes', v_ob.completion_notes,
    'source_event_id', v_ob.source_event_id,
    'source_rule_id', v_ob.source_rule_id,
    'source_reservation_id', v_ob.source_reservation_id,
    'source_decision_id', v_ob.source_decision_id,
    'metadata', v_ob.metadata,
    'created_at', v_ob.created_at);
end; $$;

revoke all on function public.obligation_detail(uuid) from public, anon;
grant execute on function public.obligation_detail(uuid) to authenticated, service_role;

comment on function public.obligation_detail(uuid) is
  'R.2R: detalle de una obligación (money o action): kind, status, title, amount, due_at, completion, provenance.';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. why_obligation_exists — provenance / explicación de origen
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.why_obligation_exists(p_obligation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
  v_rule_title text;
  v_decision_title text;
  v_event_title text;
  v_source text;
  v_reason text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  if v_caller <> v_ob.debtor_actor_id
     and v_caller <> v_ob.creditor_actor_id
     and not (v_ob.context_actor_id is not null and public.is_context_member(v_ob.context_actor_id)) then
    raise exception 'not authorized to view this obligation' using errcode = '42501';
  end if;

  if v_ob.source_rule_id is not null then
    select title into v_rule_title from public.rules where id = v_ob.source_rule_id;
    v_source := 'rule';
    v_reason := coalesce(v_ob.metadata->>'reason', v_rule_title, 'rule');
  elsif v_ob.source_decision_id is not null then
    select title into v_decision_title from public.decisions where id = v_ob.source_decision_id;
    v_source := 'decision';
    v_reason := coalesce(v_ob.metadata->>'reason', v_decision_title, 'decision');
  elsif v_ob.source_event_id is not null then
    select title into v_event_title from public.calendar_events where id = v_ob.source_event_id;
    v_source := 'event';
    v_reason := coalesce(v_ob.metadata->>'reason', v_event_title, 'event');
  elsif v_ob.source_reservation_id is not null then
    v_source := 'reservation';
    v_reason := coalesce(v_ob.metadata->>'reason', 'reservation');
  else
    v_source := 'manual';
    v_reason := coalesce(v_ob.metadata->>'reason', v_ob.metadata->>'created_by', 'manual');
  end if;

  return jsonb_build_object(
    'obligation_id', v_ob.id,
    'kind', v_ob.obligation_kind,
    'source', v_source,
    'reason', v_reason,
    'source_rule_id', v_ob.source_rule_id,
    'source_decision_id', v_ob.source_decision_id,
    'source_event_id', v_ob.source_event_id,
    'source_reservation_id', v_ob.source_reservation_id,
    'rule_title', v_rule_title,
    'metadata', v_ob.metadata);
end; $$;

revoke all on function public.why_obligation_exists(uuid) from public, anon;
grant execute on function public.why_obligation_exists(uuid) to authenticated, service_role;

comment on function public.why_obligation_exists(uuid) is
  'R.2R: explica por qué existe una obligación (regla/decisión/evento/reservación/manual) con su provenance.';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. Smokes R.2R
-- ────────────────────────────────────────────────────────────────────────────

-- 7a. Money obligation: una multa se liquida (settled) por el settlement engine.
create or replace function public._smoke_r2r_money_obligation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid; v_ctx uuid; v_code text;
  v_ob uuid; v_result jsonb; v_item record; v_detail jsonb;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R2R MoneyA', '+520000000301', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R2R MoneyB', '+520000000302', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r2r Money', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Founder multa a B con $500
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ob := ((public.record_fine(v_ctx, a_b, 500, 'MXN', 'llegó tarde'))->>'obligation_id')::uuid;

  -- La multa nace money/open
  v_detail := public.obligation_detail(v_ob);
  if v_detail->>'kind' <> 'money' then raise exception 'R2R money: kind debió ser money (% )', v_detail->>'kind'; end if;
  if v_detail->>'status' <> 'open' then raise exception 'R2R money: status inicial debió ser open'; end if;
  if (v_detail->>'amount')::numeric <> 500 then raise exception 'R2R money: amount debió ser 500'; end if;

  -- Liquidar: generar batch (nova la multa en iou) + pagar
  v_result := public.generate_settlement_batch(v_ctx, 'MXN');
  select * into v_item from public.settlement_items
   where settlement_batch_id = (v_result->>'batch_id')::uuid and status = 'pending' limit 1;
  if v_item.id is null then raise exception 'R2R money: no se generó item de settlement'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_result := public.mark_settlement_paid(v_item.id);

  -- No quedan deudas abiertas (la multa quedó settled vía novación)
  if exists (select 1 from public.obligations where context_actor_id = v_ctx and status = 'open') then
    raise exception 'R2R money: la multa no se liquidó (quedaron obligations open)';
  end if;
  if (select status from public.obligations where id = v_ob) <> 'settled' then
    raise exception 'R2R money: la multa original no quedó settled';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r2r_money_obligation passed';
end; $$;
revoke all on function public._smoke_r2r_money_obligation() from public, anon, authenticated;

-- 7b. Action obligation: David lleva vino → se completa (no toca settlement).
create or replace function public._smoke_r2r_action_obligation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid; v_ctx uuid; v_code text;
  v_ob uuid; v_detail jsonb; v_result jsonb; v_caught boolean;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R2R ActA', '+520000000303', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R2R ActB David', '+520000000304', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r2r Action', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Founder asigna a David "Llevar vino"
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ob := ((public.create_action_obligation(v_ctx, a_b, 'Llevar vino',
            p_kind := 'action', p_due_at := now() + interval '2 days'))->>'obligation_id')::uuid;

  v_detail := public.obligation_detail(v_ob);
  if v_detail->>'kind' <> 'action' then raise exception 'R2R action: kind debió ser action'; end if;
  if v_detail->>'status' <> 'open' then raise exception 'R2R action: status inicial open'; end if;
  if v_detail->>'title' <> 'Llevar vino' then raise exception 'R2R action: title incorrecto'; end if;
  if v_detail->'amount' <> 'null'::jsonb then raise exception 'R2R action: una acción no lleva amount'; end if;

  -- No creó ni tocó settlement (currency null → fuera del neteo)
  if exists (select 1 from public.settlement_batches where context_actor_id = v_ctx) then
    raise exception 'R2R action: una action obligation no debe generar settlement';
  end if;

  -- David la completa
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  v_result := public.complete_obligation(v_ob, 'Traje un Malbec');
  v_detail := public.obligation_detail(v_ob);
  if v_detail->>'status' <> 'completed' then raise exception 'R2R action: no quedó completed'; end if;
  if v_detail->>'completed_by_actor_id' <> a_b::text then raise exception 'R2R action: completed_by incorrecto'; end if;
  if v_detail->>'completion_notes' <> 'Traje un Malbec' then raise exception 'R2R action: notes no guardadas'; end if;

  -- Idempotencia
  v_result := public.complete_obligation(v_ob);
  if not coalesce((v_result->>'already_completed')::boolean, false) then
    raise exception 'R2R action: complete_obligation no es idempotente';
  end if;

  -- Un extraño no puede completar (gate de autoridad): crear C fuera del contexto
  declare u_c uuid := gen_random_uuid(); a_c uuid; v_ob2 uuid;
  begin
    a_c := public._create_person_actor_for_auth_user(u_c, 'R2R ActC', '+520000000305', null);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
    v_ob2 := ((public.create_action_obligation(v_ctx, a_b, 'Comprar hielo', p_kind := 'action'))->>'obligation_id')::uuid;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
    v_caught := false;
    begin perform public.complete_obligation(v_ob2);
    exception when insufficient_privilege then v_caught := true; end;
    if not v_caught then raise exception 'R2R action: un no-involucrado completó la obligación'; end if;
    perform set_config('request.jwt.claims', null, true);
    delete from public.person_profiles where actor_id = a_c;
    delete from public.actors where id = a_c;
    delete from auth.users where id = u_c;
  end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r2r_action_obligation passed';
end; $$;
revoke all on function public._smoke_r2r_action_obligation() from public, anon, authenticated;

-- 7c. Approval obligation: José debe aprobar contrato → completa (verificada por otro).
create or replace function public._smoke_r2r_approval_obligation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid; v_ctx uuid; v_code text;
  v_ob uuid; v_detail jsonb;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R2R ApprA Jose', '+520000000306', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R2R ApprB', '+520000000307', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r2r Approval', 'collective', 'company'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- José (founder) se asigna a sí mismo "Aprobar contrato"
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ob := ((public.create_action_obligation(v_ctx, a_a, 'Aprobar contrato', p_kind := 'approval'))->>'obligation_id')::uuid;

  v_detail := public.obligation_detail(v_ob);
  if v_detail->>'kind' <> 'approval' then raise exception 'R2R approval: kind debió ser approval'; end if;

  -- José la completa (aprueba)
  perform public.complete_obligation(v_ob, 'Contrato revisado y aprobado');
  v_detail := public.obligation_detail(v_ob);
  if v_detail->>'status' <> 'completed' then raise exception 'R2R approval: no quedó completed'; end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r2r_approval_obligation passed';
end; $$;
revoke all on function public._smoke_r2r_approval_obligation() from public, anon, authenticated;

-- 7d. Rule-generated action obligation: una regla crea "Traer botella de vino".
create or replace function public._smoke_r2r_rule_generated_action_obligation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid; v_ctx uuid; v_code text;
  v_result jsonb; v_ob uuid; v_detail jsonb; v_why jsonb;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R2R RuleA', '+520000000308', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R2R RuleB David', '+520000000309', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r2r Rule', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Regla: al hacer RSVP=going a una cena, traer botella obligatoria (action obligation)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.create_rule(
    v_ctx, 'Traer botella obligatoria',
    p_trigger_event_type := 'event.rsvp_going',
    p_condition_tree := null,  -- siempre matchea
    p_consequences := '[{"type":"create_obligation","kind":"action","title":"Traer botella de vino"}]'::jsonb);

  -- Disparar la regla para David (founder con rules.manage puede evaluar para otro)
  v_result := public.evaluate_rules_for_event(v_ctx, 'event.rsvp_going', a_b, '{}'::jsonb, null);
  if (v_result->>'rules_matched')::integer < 1 then
    raise exception 'R2R rule-action: la regla no matcheó';
  end if;

  -- Se creó una action obligation para David, sin amount
  select id into v_ob from public.obligations
   where context_actor_id = v_ctx and debtor_actor_id = a_b
     and obligation_kind = 'action' and title = 'Traer botella de vino';
  if v_ob is null then raise exception 'R2R rule-action: no se creó la action obligation'; end if;

  v_detail := public.obligation_detail(v_ob);
  if v_detail->'amount' <> 'null'::jsonb then raise exception 'R2R rule-action: action obligation con amount'; end if;
  if v_detail->>'status' <> 'open' then raise exception 'R2R rule-action: status inicial open'; end if;

  -- why_obligation_exists apunta a la regla de origen
  v_why := public.why_obligation_exists(v_ob);
  if v_why->>'source' <> 'rule' then raise exception 'R2R rule-action: source debió ser rule'; end if;
  if (v_why->>'source_rule_id') is null then raise exception 'R2R rule-action: falta source_rule_id'; end if;

  -- Idempotencia del motor: re-evaluar no duplica la obligación
  perform public.evaluate_rules_for_event(v_ctx, 'event.rsvp_going', a_b, '{}'::jsonb, null);
  if (select count(*) from public.obligations
       where context_actor_id = v_ctx and debtor_actor_id = a_b
         and obligation_kind = 'action' and title = 'Traer botella de vino') <> 1 then
    raise exception 'R2R rule-action: la regla duplicó la action obligation';
  end if;

  -- David la completa
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.complete_obligation(v_ob, 'Llevé un tinto');
  if (select status from public.obligations where id = v_ob) <> 'completed' then
    raise exception 'R2R rule-action: no quedó completed';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r2r_rule_generated_action_obligation passed';
end; $$;
revoke all on function public._smoke_r2r_rule_generated_action_obligation() from public, anon, authenticated;

-- 7e. Backward compatibility: el dinero existente (expense split + neteo) no se rompe.
create or replace function public._smoke_r2r_backward_compatibility()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid(); u_c uuid := gen_random_uuid();
  a_a uuid; a_b uuid; a_c uuid; v_ctx uuid; v_code text;
  v_kinds int; v_amounts int;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R2R BcA', '+520000000310', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R2R BcB', '+520000000311', null);
  a_c := public._create_person_actor_for_auth_user(u_c, 'R2R BcC', '+520000000312', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r2r Backcompat', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- record_expense crea expense_share obligations que deben defaultear a kind=money con amount
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.record_expense(v_ctx, 300, 'MXN', 'Súper',
    p_split_with := array[a_a, a_b, a_c], p_client_id := 'r2r-bc-super');

  select count(*) into v_amounts from public.obligations
   where context_actor_id = v_ctx and obligation_type = 'expense_share';
  if v_amounts <> 2 then raise exception 'R2R backcompat: esperaba 2 expense_share obligations'; end if;

  -- TODAS las obligaciones de dinero existentes tienen kind=money (default backfill) y amount
  select count(*) into v_kinds from public.obligations
   where context_actor_id = v_ctx and obligation_kind = 'money' and amount is not null;
  if v_kinds <> 2 then raise exception 'R2R backcompat: las obligations de dinero perdieron kind/amount'; end if;

  -- El neteo (R.2N) sigue funcionando con la columna nueva presente
  perform public.generate_settlement_batch(v_ctx, 'MXN');
  if (select coalesce(sum(amount), 0) from public.obligations
       where context_actor_id = v_ctx and obligation_kind = 'money'
         and obligation_type = 'iou' and status = 'open') <> 200 then
    raise exception 'R2R backcompat: el neteo en ious cambió de comportamiento';
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b, a_c], array[u_a, u_b, u_c]);
  raise notice '_smoke_r2r_backward_compatibility passed';
end; $$;
revoke all on function public._smoke_r2r_backward_compatibility() from public, anon, authenticated;

-- 7f. Wrapper CI: el runner ejecuta todo _smoke_mvp2_* — agrupa los 5 smokes R.2R.
create or replace function public._smoke_mvp2_r2r_universal_obligations()
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
  perform public._smoke_r2r_money_obligation();
  perform public._smoke_r2r_action_obligation();
  perform public._smoke_r2r_approval_obligation();
  perform public._smoke_r2r_rule_generated_action_obligation();
  perform public._smoke_r2r_backward_compatibility();
  raise notice 'R.2R UNIVERSAL OBLIGATIONS: PASS — money + action + approval + rule-generated + backward-compat.';
end; $$;
revoke all on function public._smoke_mvp2_r2r_universal_obligations() from public, anon, authenticated;

comment on function public._smoke_mvp2_r2r_universal_obligations() is
  'R.2R DoD: obligations universal (dinero y acción) sin tabla task; money intacto; reglas generan action obligations.';
