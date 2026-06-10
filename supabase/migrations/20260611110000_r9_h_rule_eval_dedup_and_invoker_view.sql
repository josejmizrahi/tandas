-- ═══ R.9.H — Dedup real de evaluación de reglas (fix multa doble R.6.B)
--         + actor_money_balances a SECURITY INVOKER (advisor ERROR). ═══
--
-- Bug (en producción): una regla cuya condición no referencia event_type
-- dispara DOS veces en check-in:
--   1. El trigger AFTER INSERT sobre activity_events (_r6_dispatch_rule_eval)
--      pasa p_source_event_id = activity_event.id → la traducción a
--      calendar_event falla → idempotency key A, obligación con
--      source_event_id NULL.
--   2. La eval síncrona dentro de check_in_participant pasa el calendar
--      event id real → idempotency key B, segunda obligación.
-- Resultado: multa doble (reproducido en _smoke_mvp2_contract pre-r9_g:
-- Linda neteaba 500 en vez de 400; r9_g lo esquivó dándole event_type a la
-- regla del smoke — este migration arregla la causa raíz).
--
-- Fix:
--   a. _r6_dispatch_rule_eval resuelve el calendar event REAL desde la
--      activity row (payload->>'event_id' → subject calendar_event →
--      subject event_participant) y lo pasa como p_source_event_id → ambos
--      paths convergen a la misma idempotency key → dedup por unique index.
--   b. _r6_eval_rules_core: el branch de conflicto reporta la evaluación
--      previa (matched + consecuencias already_existed) en vez de `continue`
--      silencioso — check_in_participant sigue regresando rules_matched ≥ 1
--      aunque el trigger haya evaluado primero (orden: trigger corre ANTES,
--      dentro del INSERT de _emit_activity; la síncrona después).
--   c. actor_money_balances: la vista no filtraba por caller y corría con
--      derechos del owner (bypass de RLS) → cualquier authenticated podía
--      leer los balances de TODOS los contextos. security_invoker = true
--      delega a la RLS de ledger_entries (miembros del contexto o self).
--
-- Smoke: _smoke_mvp2_r9_h_rule_eval_dedup (CI vía edge-tests).

-- ── 1. _r6_eval_rules_core — copia exacta de 20260611105000 (r9_e) + branch
--       de conflicto que reporta la evaluación previa.

create or replace function public._r6_eval_rules_core(
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
set row_security to off
as $$
declare
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
  v_calendar_event_id uuid;
  v_subject_active boolean := false;
  v_prev_outcome text;
  v_prev_cons jsonb;
begin
  -- Translate p_source_event_id → calendar_event_id si existe en la tabla.
  -- Trigger path pasa activity_event.id (no calendar_event); wrapper manual pasa el real.
  if p_source_event_id is not null then
    select id into v_calendar_event_id
      from public.calendar_events where id = p_source_event_id;
  end if;

  -- R.9.E — Snapshot de membresía del subject al momento de evaluar.
  -- Sin membresía ACTIVA en el contexto de la regla, las consecuencias que
  -- crean obligaciones/multas se saltan (no phantom fines para removidos/
  -- salidos). Los placeholders SÍ tienen membership_status = 'active'
  -- (R.5W slice 1) → siguen siendo multables.
  select exists (
    select 1 from public.actor_memberships am
     where am.context_actor_id = p_context_actor_id
       and am.member_actor_id = p_subject_actor_id
       and am.membership_status = 'active'
  ) into v_subject_active;

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

    if v_eval_id is null then
      -- R.9.H: la evaluación ya existe (el otro path — trigger o síncrono —
      -- llegó primero con la MISMA key). Reportar su resultado en vez de
      -- omitirlo: el caller sigue viendo rules_matched/obligations aunque
      -- la consecuencia se haya creado en el otro path (already_existed).
      select id, outcome, consequences_emitted
        into v_eval_id, v_prev_outcome, v_prev_cons
        from public.rule_evaluations
       where idempotency_key = v_idempotency_key
       limit 1;
      if v_prev_outcome = 'matched' then
        v_matched := v_matched + 1;
        v_obligations := v_obligations || coalesce(v_prev_cons->'obligations', '[]'::jsonb);
        v_attentions  := v_attentions  || coalesce(v_prev_cons->'attentions',  '[]'::jsonb);
        continue;
      elsif v_outcome = 'not_matched' then
        continue;
      end if;
      -- R.9.H: la evaluación previa fue not_matched pero ESTA sí matchea.
      -- Payload asimétrico: el trigger evalúa con el payload de activity (que
      -- puede carecer de campos como event_type) y el path síncrono con el
      -- payload enriquecido. Upgrade de la evaluación a matched y caemos al
      -- branch de consecuencias (el guard de obligación existente + la key de
      -- attention dedupean, así que no hay doble multa).
      update public.rule_evaluations
         set outcome = 'matched',
             metadata = jsonb_build_object(
               'subject_actor_id', p_subject_actor_id, 'payload', p_payload,
               'upgraded_from', 'not_matched')
       where id = v_eval_id;
    end if;

    if v_outcome = 'matched' then
      v_matched := v_matched + 1;
      v_consequence_index := 0;

      for v_consequence in select * from jsonb_array_elements(coalesce(v_rule.consequences, '[]'::jsonb)) loop
        if v_consequence->>'type' in ('fine', 'create_obligation') then
          -- R.9.E guard: subject sin membresía activa → skip de la consecuencia,
          -- con nota en consequences_emitted de la evaluación (mismo shape que
          -- las entradas normales de 'obligations').
          if not v_subject_active then
            v_rule_obligations := v_rule_obligations || jsonb_build_object(
              'obligation_id', null,
              'rule_id', v_rule.id,
              'kind', coalesce(v_consequence->>'kind', 'money'),
              'skipped', true,
              'skip_reason', 'subject_not_active_member');
            v_consequence_index := v_consequence_index + 1;
            continue;
          end if;

          v_kind := coalesce(v_consequence->>'kind', 'money');
          v_title := coalesce(v_consequence->>'title', v_rule.title);
          v_reason := coalesce(v_consequence->>'reason', v_consequence->>'title', v_rule.title);

          select id into v_existing from public.obligations
           where source_rule_id = v_rule.id
             and source_event_id is not distinct from v_calendar_event_id
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
                 v_calendar_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope,
                   'source_activity_event_id', p_source_event_id))
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
                 v_calendar_event_id, v_rule.id,
                 jsonb_build_object(
                   'reason', v_reason, 'participant_actor_id', p_subject_actor_id,
                   'triggering_event_type', p_trigger_event_type, 'rule_evaluation_id', v_eval_id,
                   'rule_title', v_rule.title, 'trigger', p_trigger_event_type,
                   'target_scope', v_rule.target_scope,
                   'source_activity_event_id', p_source_event_id))
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

-- ── 2. _r6_dispatch_rule_eval — copia de 20260608111234 (r6_b) + resolución
--       del calendar event real.

create or replace function public._r6_dispatch_rule_eval()
returns trigger
language plpgsql
security definer
set search_path to public, auth
as $$
declare
  v_source uuid;
  v_cal uuid;
begin
  -- Guards anti-recursión (idénticos a r6_b):
  if NEW.payload ? 'system' and (NEW.payload->>'system')::boolean = true then return null; end if;
  if NEW.event_type like 'rule.%' then return null; end if;
  if NEW.event_type like 'fine.created' then return null; end if;

  -- Skip si falta scope o subject.
  if NEW.context_actor_id is null then return null; end if;
  if NEW.actor_id is null then return null; end if;

  -- R.9.H: resolver el calendar event REAL de la activity para que la
  -- idempotency key coincida con la del path síncrono y la segunda
  -- evaluación dedupe (antes: NEW.id = activity id → key distinta → doble).
  v_source := NEW.id;
  begin
    v_cal := nullif(NEW.payload->>'event_id', '')::uuid;
  exception when others then
    v_cal := null;
  end;
  if v_cal is not null then
    select id into v_cal from public.calendar_events where id = v_cal;
  end if;
  if v_cal is null and NEW.subject_type = 'calendar_event' then
    select id into v_cal from public.calendar_events where id = NEW.subject_id;
  end if;
  if v_cal is null and NEW.subject_type = 'event_participant' then
    select ep.event_id into v_cal from public.event_participants ep where ep.id = NEW.subject_id;
  end if;
  if v_cal is not null then
    v_source := v_cal;
  end if;

  begin
    perform public._r6_eval_rules_core(
      p_context_actor_id := NEW.context_actor_id,
      p_trigger_event_type := NEW.event_type,
      p_subject_actor_id := NEW.actor_id,
      p_payload := coalesce(NEW.payload, '{}'::jsonb),
      p_source_event_id := v_source
    );
  exception when others then
    -- Best-effort: warn pero no romper la activity insertion.
    raise warning 'R.6.B rule dispatch failed for activity_event % type=%: %',
      NEW.id, NEW.event_type, sqlerrm;
  end;

  return null;
end;
$$;

-- El trigger (trg_r6_dispatch_rule_eval) apunta a la misma función; no se recrea.

-- ── 3. actor_money_balances → SECURITY INVOKER (visibilidad vía RLS de
--       ledger_entries: miembros del contexto o self — 20260604130002).

alter view public.actor_money_balances set (security_invoker = true);

-- ── 4. Smoke

create or replace function public._smoke_mvp2_r9_h_rule_eval_dedup()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  u_admin uuid; a_admin uuid;
  u_m uuid; a_m uuid;
  u_x uuid; a_x uuid;
  v_ctx uuid; v_code text; v_event uuid;
  v_result jsonb;
  v_n integer;
begin
  select auth_id, actor_id into u_admin, a_admin from public._r2_make_person('Ana R9H', '+5210000971');
  select auth_id, actor_id into u_m, a_m from public._r2_make_person('Memo R9H', '+5210000972');
  select auth_id, actor_id into u_x, a_x from public._r2_make_person('Xeno R9H', '+5210000973');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  v_ctx := (public.create_context('R9H Dedup', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_m::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Regla SIN condición de event_type (el caso que multaba doble) + evento tarde.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  perform public.create_rule(v_ctx::uuid, 'R9H Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);
  v_event := (public.create_calendar_event(v_ctx::uuid, 'R9H Cena', 'dinner',
    p_location_text := 'Por definir', p_starts_at := now() - interval '30 minutes'))->>'event_id';

  -- ═══ 1. Check-in tarde → EXACTAMENTE UNA multa (antes: dos) ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_m::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'r9_h 1: el retorno síncrono perdió rules_matched (semántica rota): %', v_result;
  end if;

  select count(*) into v_n from public.obligations
   where context_actor_id = v_ctx::uuid and debtor_actor_id = a_m and obligation_type = 'fine';
  if v_n <> 1 then
    raise exception 'r9_h 1: esperaba exactamente 1 multa, hay % (doble eval no deduplicada)', v_n;
  end if;

  select count(*) into v_n from public.rule_evaluations re
   join public.rules r on r.id = re.rule_id
   where r.context_actor_id = v_ctx::uuid and re.outcome = 'matched';
  if v_n <> 1 then
    raise exception 'r9_h 1: esperaba exactamente 1 rule_evaluation matched, hay %', v_n;
  end if;

  -- ═══ 2. Vista de balances con security_invoker: miembro ve, extraño no ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_admin::text)::text, true);
  perform public.record_expense(v_ctx::uuid, 300, 'MXN', 'r9h gasto');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_m::text)::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.actor_money_balances where context_actor_id = v_ctx::uuid;
  if v_n < 1 then
    execute 'reset role';
    raise exception 'r9_h 2: miembro no ve balances de su contexto (invoker rompió visibilidad)';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_x::text)::text, true);
  select count(*) into v_n from public.actor_money_balances where context_actor_id = v_ctx::uuid;
  execute 'reset role';
  if v_n <> 0 then
    raise exception 'r9_h 2: un NO-miembro ve % filas de balances ajenos (fuga RLS)', v_n;
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_admin, a_m, a_x], array[u_admin, u_m, u_x]);

  raise notice '_smoke_mvp2_r9_h_rule_eval_dedup passed (1 multa exacta, retorno síncrono intacto, invoker view con RLS)';
end;
$$;

revoke all on function public._smoke_mvp2_r9_h_rule_eval_dedup() from public, anon, authenticated;

comment on function public._smoke_mvp2_r9_h_rule_eval_dedup() is
  'R.9.H: dedup de evaluación de reglas entre trigger y path síncrono (multa única) + actor_money_balances security_invoker.';
