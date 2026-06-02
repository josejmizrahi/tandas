-- ============================================================================
-- MVP 2.0 — M.10 DOCUMENTS + CONTEXT SUMMARY v2 + M.11 CONTRACT SMOKE
-- ============================================================================
-- documents + context_summary extendido (resources/events/money) +
-- smoke de contrato end-to-end (cena semanal completa: contexto → invite →
-- regla → evento → check-in tarde → multa → gasto → settlement → summary).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. documents
-- ────────────────────────────────────────────────────────────────────────────
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  owner_actor_id uuid references public.actors(id),
  context_actor_id uuid references public.actors(id) on delete cascade,
  title text not null,
  document_type text check (document_type in
    ('contract', 'receipt', 'id', 'statement', 'photo', 'other')),
  storage_path text,
  mime_type text,
  file_size_bytes bigint,
  resource_id uuid references public.resources(id),
  decision_id uuid references public.decisions(id),
  event_id uuid references public.calendar_events(id),
  metadata jsonb not null default '{}',
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create index idx_documents_context on public.documents (context_actor_id) where archived_at is null;
create index idx_documents_owner on public.documents (owner_actor_id) where archived_at is null;

create trigger trg_documents_touch before update on public.documents
  for each row execute function public.touch_updated_at();

alter table public.documents enable row level security;
create policy documents_select on public.documents
  for select to authenticated
  using (
    owner_actor_id = public.current_actor_id()
    or created_by_actor_id = public.current_actor_id()
    or (context_actor_id is not null and public.is_context_member(context_actor_id))
  );
revoke all on public.documents from anon;

-- register_document: metadata del archivo (el upload va a Supabase Storage desde el cliente)
create or replace function public.register_document(
  p_title text,
  p_context_actor_id uuid default null,
  p_document_type text default 'other',
  p_storage_path text default null,
  p_mime_type text default null,
  p_file_size_bytes bigint default null,
  p_resource_id uuid default null,
  p_event_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_context_actor_id is not null
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'documents.manage')
     and not public.has_actor_authority(p_context_actor_id, v_caller, 'documents.view') then
    raise exception 'not authorized to add documents to context %', p_context_actor_id using errcode = '42501';
  end if;

  insert into public.documents
    (owner_actor_id, context_actor_id, title, document_type, storage_path, mime_type,
     file_size_bytes, resource_id, event_id, metadata, created_by_actor_id)
  values
    (v_caller, p_context_actor_id, btrim(p_title), p_document_type, p_storage_path, p_mime_type,
     p_file_size_bytes, p_resource_id, p_event_id, coalesce(p_metadata, '{}'::jsonb), v_caller)
  returning id into v_id;

  perform public._emit_activity(coalesce(p_context_actor_id, v_caller), v_caller, 'document.registered', 'document', v_id,
    jsonb_build_object('title', btrim(p_title), 'document_type', p_document_type),
    p_resource_id := p_resource_id);

  return jsonb_build_object('document_id', v_id);
end; $$;

revoke all on function public.register_document(text, uuid, text, text, text, bigint, uuid, uuid, jsonb) from public, anon;
grant execute on function public.register_document(text, uuid, text, text, text, bigint, uuid, uuid, jsonb) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. context_summary v2 — secciones completas (reemplaza la versión M.3)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.context_summary(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  return jsonb_build_object(
    'context', (select to_jsonb(a) from public.actors a where a.id = p_context_actor_id),
    'as_of', now(),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'actor_id', m.member_actor_id, 'display_name', a.display_name,
        'membership_type', m.membership_type, 'joined_at', m.joined_at,
        'roles', coalesce((select jsonb_agg(r.role_key)
          from public.role_assignments ra join public.roles r on r.id = ra.role_id
          where ra.context_actor_id = m.context_actor_id and ra.member_actor_id = m.member_actor_id), '[]'::jsonb)
      ) order by m.joined_at)
      from public.actor_memberships m join public.actors a on a.id = m.member_actor_id
      where m.context_actor_id = p_context_actor_id and m.membership_status = 'active'), '[]'::jsonb),
    'my_permissions', coalesce((
      select jsonb_agg(distinct rp.permission_key)
        from public.role_assignments ra
        join public.role_permissions rp on rp.role_id = ra.role_id and rp.allowed
       where ra.context_actor_id = p_context_actor_id and ra.member_actor_id = v_caller), '[]'::jsonb),
    'resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'resource_id', r.id, 'display_name', r.display_name, 'resource_type', r.resource_type,
        'estimated_value', r.estimated_value, 'currency', r.currency) order by r.created_at desc)
      from (select * from public.resources
            where canonical_owner_actor_id = p_context_actor_id and archived_at is null
            order by created_at desc limit 20) r), '[]'::jsonb),
    'upcoming_events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_id', e.id, 'title', e.title, 'event_type', e.event_type,
        'starts_at', e.starts_at, 'host_actor_id', e.host_actor_id, 'status', e.status) order by e.starts_at)
      from (select * from public.calendar_events
            where context_actor_id = p_context_actor_id and status = 'scheduled'
              and (starts_at is null or starts_at > now() - interval '1 day')
            order by starts_at limit 10) e), '[]'::jsonb),
    'open_decisions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'decision_id', d.id, 'title', d.title, 'decision_type', d.decision_type,
        'created_at', d.created_at) order by d.created_at desc)
      from (select * from public.decisions
            where context_actor_id = p_context_actor_id and status = 'open'
            order by created_at desc limit 10) d), '[]'::jsonb),
    'money', jsonb_build_object(
      'open_obligations', coalesce((
        select jsonb_agg(jsonb_build_object(
          'obligation_id', o.id, 'debtor_actor_id', o.debtor_actor_id,
          'creditor_actor_id', o.creditor_actor_id, 'obligation_type', o.obligation_type,
          'amount', o.amount, 'currency', o.currency) order by o.created_at desc)
        from (select * from public.obligations
              where context_actor_id = p_context_actor_id and status = 'open'
              order by created_at desc limit 20) o), '[]'::jsonb),
      'my_balance', coalesce((
        select sum(case when creditor_actor_id = v_caller then amount
                        when debtor_actor_id = v_caller then -amount
                        else 0 end)
        from public.obligations
        where context_actor_id = p_context_actor_id and status = 'open'), 0)),
    'active_rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'rule_id', r.id, 'title', r.title, 'trigger_event_type', r.trigger_event_type) order by r.created_at)
      from public.rules r
      where r.context_actor_id = p_context_actor_id and r.status = 'active'), '[]'::jsonb),
    'recent_activity', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', ae.event_type, 'actor_id', ae.actor_id, 'payload', ae.payload,
        'occurred_at', ae.occurred_at) order by ae.occurred_at desc)
      from (select * from public.activity_events
            where context_actor_id = p_context_actor_id
            order by occurred_at desc limit 20) ae), '[]'::jsonb)
  );
end; $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. M.11 — Contract smoke end-to-end (cena semanal completa)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_contract()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_jose uuid := gen_random_uuid();
  v_auth_linda uuid := gen_random_uuid();
  v_jose uuid; v_linda uuid; v_ctx uuid;
  v_result jsonb; v_code text; v_event uuid; v_next uuid;
  v_batch uuid; v_item uuid; v_summary jsonb;
begin
  -- ═══ 1. Identity: dos personas se registran ═══
  v_jose := public._create_person_actor_for_auth_user(v_auth_jose, 'Jose Contract', '+520000000022', null);
  v_linda := public._create_person_actor_for_auth_user(v_auth_linda, 'Linda Contract', '+520000000023', null);

  -- ═══ 2. Jose crea el contexto "Cena de los Jueves" ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_ctx := (public.create_context('_contract Cena de los Jueves', 'collective', 'friend_group'))->>'context_actor_id';

  -- ═══ 3. Linda se une con invite code ═══
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- ═══ 4. Jose define la regla: tarde > 15 min → multa $100 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  perform public.create_rule(v_ctx::uuid, '_contract Multa por tarde',
    p_trigger_event_type := 'event.checked_in',
    p_condition_tree := '{"op": ">", "field": "minutes_late", "value": 15}'::jsonb,
    p_consequences := '[{"type": "fine", "amount": 100, "currency": "MXN"}]'::jsonb);

  -- ═══ 5. Cena semanal recurrente (ya empezó hace 30 min) ═══
  v_event := (public.create_calendar_event(v_ctx::uuid, '_contract Cena Jueves', 'dinner',
    p_starts_at := now() - interval '30 minutes',
    p_recurrence_rule := 'weekly', p_host_actor_id := v_jose))->>'event_id';

  -- ═══ 6. Jose check-in a "tiempo" (él es host, llegó hace 30... también tarde) ═══
  --        Linda hace check-in tarde → multa automática $100
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  v_result := public.check_in_participant(v_event::uuid);
  if (v_result->'rules'->>'rules_matched')::integer < 1 then
    raise exception 'contract: multa automática por tarde no se generó';
  end if;

  -- ═══ 7. Jose paga la cena $600 → split 50/50 → Linda debe $300 ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_jose::text)::text, true);
  v_result := public.record_expense(v_ctx::uuid, 600, 'MXN', '_contract Cena sushi', p_event_id := v_event::uuid);
  if (v_result->>'share_per_person')::numeric <> 300 then
    raise exception 'contract: split de gasto incorrecto';
  end if;

  -- ═══ 8. Cerrar el evento → siguiente cena creada con host rotado a Linda ═══
  v_result := public.close_event(v_event::uuid);
  v_next := (v_result->>'next_event_id')::uuid;
  if v_next is null or (v_result->>'next_host_actor_id')::uuid is distinct from v_linda then
    raise exception 'contract: recurrencia/rotación de host falló';
  end if;

  -- ═══ 9. Settlement: Linda debe $300 (gasto) + $100 (multa) = $400 ═══
  v_result := public.generate_settlement_batch(v_ctx::uuid, 'MXN');
  v_batch := (v_result->>'batch_id')::uuid;
  if v_batch is null then raise exception 'contract: settlement batch no generado'; end if;
  -- Linda neto: -400 (300 a Jose + 100 al contexto)
  if (select sum((i->>'amount')::numeric) from jsonb_array_elements(v_result->'items') i
      where (i->>'from')::uuid = v_linda) <> 400 then
    raise exception 'contract: neteo de Linda incorrecto (esperaba 400)';
  end if;

  -- ═══ 10. Linda paga su settlement ═══
  select id into v_item from public.settlement_items
   where settlement_batch_id = v_batch and from_actor_id = v_linda limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_linda::text)::text, true);
  v_result := public.mark_settlement_paid(v_item);
  if (v_result->>'obligations_closed')::integer < 1 then
    raise exception 'contract: obligations no cerradas con el pago';
  end if;

  -- ═══ 11. context_summary refleja TODO ═══
  v_summary := public.context_summary(v_ctx::uuid);
  if jsonb_array_length(v_summary->'members') <> 2 then
    raise exception 'contract: summary.members incorrecto';
  end if;
  if jsonb_array_length(v_summary->'upcoming_events') < 1 then
    raise exception 'contract: summary.upcoming_events no muestra la siguiente cena';
  end if;
  if jsonb_array_length(v_summary->'active_rules') <> 1 then
    raise exception 'contract: summary.active_rules incorrecto';
  end if;
  if jsonb_array_length(v_summary->'recent_activity') < 5 then
    raise exception 'contract: summary.recent_activity incompleta';
  end if;

  -- ═══ 12. context_candidates de Linda muestra el contexto ═══
  v_result := public.context_candidates();
  if not exists (select 1 from jsonb_array_elements(v_result->'contexts') c
                 where (c->>'context_actor_id')::uuid = v_ctx::uuid) then
    raise exception 'contract: context_candidates no muestra el contexto';
  end if;

  -- ═══ Cleanup ═══
  perform set_config('request.jwt.claims', null, true);
  delete from public.settlement_items where settlement_batch_id in
    (select id from public.settlement_batches where context_actor_id = v_ctx::uuid);
  delete from public.settlement_batches where context_actor_id = v_ctx::uuid;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = v_ctx::uuid);
  delete from public.money_transactions where context_actor_id = v_ctx::uuid;
  delete from public.rule_evaluations where context_actor_id = v_ctx::uuid;
  delete from public.obligations where context_actor_id = v_ctx::uuid;
  delete from public.rules where context_actor_id = v_ctx::uuid;
  delete from public.event_participants where event_id in
    (select id from public.calendar_events where context_actor_id = v_ctx::uuid);
  delete from public.calendar_events where context_actor_id = v_ctx::uuid;
  delete from public.documents where context_actor_id = v_ctx::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_jose, v_linda);
  delete from public.actors where id in (v_jose, v_linda);
  delete from auth.users where id in (v_auth_jose, v_auth_linda);

  raise notice '_smoke_mvp2_contract passed (cena semanal end-to-end: contexto → invite → regla → evento → check-in tarde → multa → gasto → split → recurrencia + host rotation → settlement → pago → summary)';
end; $$;

revoke all on function public._smoke_mvp2_contract() from public, anon, authenticated;

comment on function public._smoke_mvp2_contract() is 'Smoke MVP2 contrato: el escenario cena semanal completo end-to-end con todos los dominios.';
