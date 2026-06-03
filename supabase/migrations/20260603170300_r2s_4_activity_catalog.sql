-- ============================================================================
-- R.2S.8 — ACTIVITY EVENT CATALOG
-- ============================================================================
-- Activity deja de ser un log caótico de strings arbitrarios. Se cataloga la
-- taxonomía canónica (la que produce el gateway _emit_activity tras normalizar
-- los nombres legacy) en activity_event_catalog. El gateway marca como
-- uncatalogued cualquier tipo fuera del catálogo salvo los custom.* (que
-- quedan permitidos con metadata).
--
--   activity_event_catalog(event_type, domain, description,
--                          expected_subject_type, expected_payload_schema,
--                          is_system_generated)
--
-- DoD: activity_events usa tipos catalogados; no hay event_type arbitrario
-- fuera del catálogo salvo custom; list_activity devuelve timeline reconstruible.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. activity_event_catalog
-- ────────────────────────────────────────────────────────────────────────────
create table public.activity_event_catalog (
  event_type text primary key,
  domain text not null,
  description text,
  expected_subject_type text,
  expected_payload_schema jsonb not null default '{}',
  is_system_generated boolean not null default false,
  created_at timestamptz not null default now()
);

comment on table public.activity_event_catalog is
  'R.2S.8: catálogo de la taxonomía canónica de activity. event_type fuera de aquí (salvo custom.*) se marca uncatalogued.';

alter table public.activity_event_catalog enable row level security;
create policy activity_event_catalog_select on public.activity_event_catalog
  for select to authenticated using (true);
revoke all on public.activity_event_catalog from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Seed: taxonomía canónica completa (todo lo que emite el backend)
-- ────────────────────────────────────────────────────────────────────────────
insert into public.activity_event_catalog (event_type, domain, description, expected_subject_type, is_system_generated) values
  ('context.created',                'context',     'Se creó un contexto',                         'actor',              false),
  ('invite.created',                 'membership',  'Se generó una invitación',                    'invite',             false),
  ('membership.invited',             'membership',  'Se invitó a un actor',                        'actor',              false),
  ('membership.joined',              'membership',  'Un actor se unió al contexto',                'actor',              false),
  ('membership.left',                'membership',  'Un actor dejó el contexto',                   'actor',              false),
  ('membership.removed',             'membership',  'Se removió a un actor',                       'actor',              false),
  ('role.assigned',                  'membership',  'Se asignó un rol',                            'actor',              false),

  ('resource.created',               'resource',    'Se creó un recurso',                          'resource',           false),
  ('resource.updated',               'resource',    'Se actualizó un recurso',                     'resource',           false),
  ('resource.archived',              'resource',    'Se archivó un recurso',                       'resource',           false),
  ('right.granted',                  'resource',    'Se otorgó un derecho sobre un recurso',       'resource',           false),
  ('right.revoked',                  'resource',    'Se revocó un derecho sobre un recurso',       'resource',           false),
  ('document.created',               'resource',    'Se registró un documento',                    'document',           false),

  ('event.created',                  'event',       'Se creó un evento',                           'calendar_event',     false),
  ('event.rsvp_updated',             'event',       'Cambió el RSVP de un participante',           'calendar_event',     false),
  ('event.checked_in',              'event',       'Un participante hizo check-in',               'calendar_event',     false),
  ('event.participation_cancelled',  'event',       'Un participante canceló su asistencia',       'calendar_event',     false),
  ('event.closed',                   'event',       'Se cerró un evento',                          'calendar_event',     false),

  ('rule.created',                   'rule',        'Se creó una regla',                           'rule',               false),
  ('rule.evaluated',                 'rule',        'Una regla se evaluó automáticamente',         'rule',               true),

  ('obligation.created',             'obligation',  'Se creó una obligación',                      'obligation',         false),
  ('obligation.completed',           'obligation',  'Se cumplió una obligación de acción',         'obligation',         false),
  ('fine.created',                   'obligation',  'Se registró una multa',                       'obligation',         false),

  ('reservation.requested',          'reservation', 'Se solicitó una reservación',                 'reservation',        false),
  ('reservation.approved',           'reservation', 'Se aprobó una reservación',                   'reservation',        false),
  ('reservation.rejected',           'reservation', 'Se rechazó una reservación',                  'reservation',        false),
  ('reservation.confirmed',          'reservation', 'Se confirmó una reservación',                 'reservation',        false),
  ('reservation.cancelled',          'reservation', 'Se canceló una reservación',                  'reservation',        false),
  ('reservation.conflict_detected',  'reservation', 'Se detectó un conflicto de reservación',      'reservation_conflict', true),
  ('reservation.conflict_resolved',  'reservation', 'Se resolvió un conflicto de reservación',     'reservation_conflict', false),

  ('decision.created',               'decision',    'Se abrió una decisión',                       'decision',           false),
  ('decision.vote_cast',             'decision',    'Se emitió un voto',                           'decision',           false),
  ('decision.closed',                'decision',    'Se cerró la votación de una decisión',        'decision',           false),
  ('decision.approved',              'decision',    'Una decisión quedó aprobada',                 'decision',           false),
  ('decision.rejected',              'decision',    'Una decisión quedó rechazada',                'decision',           false),
  ('decision.executed',              'decision',    'Se ejecutó el resultado de una decisión',     'decision',           false),

  ('expense.recorded',               'money',       'Se registró un gasto',                        'money_transaction',  false),
  ('split.generated',                'money',       'Se generó el reparto de un gasto',            'money_transaction',  false),
  ('game_result.recorded',           'money',       'Se registró el resultado de un juego',        'money_transaction',  false),

  ('settlement.generated',           'settlement',  'Se generó un lote de liquidación',            'settlement_batch',   false),
  ('settlement.item_created',        'settlement',  'Se creó una transferencia de liquidación',    'settlement_item',    true),
  ('settlement.paid',                'settlement',  'Se marcó como pagada una liquidación',        'settlement_item',    false);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. _emit_activity v3: marca uncatalogued lo que no esté en el catálogo
-- ────────────────────────────────────────────────────────────────────────────
-- Preserva toda la normalización legacy de R.2J. Solo agrega: si el tipo
-- canónico no está catalogado y no es custom.*, lo marca con payload.uncatalogued.
create or replace function public._emit_activity(
  p_context_actor_id uuid,
  p_actor_id uuid,
  p_event_type text,
  p_subject_type text default null,
  p_subject_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_resource_id uuid default null,
  p_decision_id uuid default null,
  p_obligation_id uuid default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_type text;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  v_type := case p_event_type
    when 'member.joined'              then 'membership.joined'
    when 'member.invited'             then 'membership.invited'
    when 'member.removed'             then 'membership.removed'
    when 'member.left'                then 'membership.left'
    when 'document.registered'        then 'document.created'
    when 'money.expense_recorded'     then 'expense.recorded'
    when 'money.fine_recorded'        then 'fine.created'
    when 'money.game_result_recorded' then 'game_result.recorded'
    when 'money.settlement_generated' then 'settlement.generated'
    when 'money.settlement_paid'      then 'settlement.paid'
    when 'event.rsvp'                 then 'event.rsvp_updated'
    else p_event_type
  end;

  if v_type like 'settlement.%' then
    if p_subject_type = 'settlement_batch' and p_subject_id is not null then
      v_payload := v_payload || jsonb_build_object('settlement_batch_id', p_subject_id);
    elsif p_subject_type = 'settlement_item' and p_subject_id is not null then
      v_payload := v_payload || jsonb_build_object('settlement_item_id', p_subject_id);
    end if;
    if v_payload ? 'batch_id' and not v_payload ? 'settlement_batch_id' then
      v_payload := v_payload || jsonb_build_object('settlement_batch_id', v_payload->'batch_id');
    end if;
  end if;

  if v_type in ('rule.evaluated', 'reservation.conflict_detected', 'settlement.item_created') then
    v_payload := v_payload || '{"system": true}'::jsonb;
  end if;

  -- R.2S.8: marcar tipos fuera del catálogo (salvo custom.*) como uncatalogued
  if not exists (select 1 from public.activity_event_catalog c where c.event_type = v_type)
     and v_type not like 'custom.%' then
    v_payload := v_payload || '{"uncatalogued": true}'::jsonb;
  end if;

  insert into public.activity_events
    (context_actor_id, actor_id, event_type, subject_type, subject_id, payload,
     resource_id, decision_id, obligation_id)
  values
    (p_context_actor_id, coalesce(p_actor_id, public.system_actor_id()), v_type,
     p_subject_type, p_subject_id, v_payload,
     p_resource_id, p_decision_id, p_obligation_id)
  returning id into v_id;
  return v_id;
end; $$;

revoke all on function public._emit_activity(uuid, uuid, text, text, uuid, jsonb, uuid, uuid, uuid) from public, anon, authenticated;

comment on function public._emit_activity(uuid, uuid, text, text, uuid, jsonb, uuid, uuid, uuid) is
  'R.2S.8: gateway de activity. Normaliza taxonomía canónica, valida contra activity_event_catalog (marca uncatalogued lo no catalogado salvo custom.*).';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. activity_event_catalog(): catálogo para el frontend
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.activity_event_catalog()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'event_type', c.event_type,
    'domain', c.domain,
    'description', c.description,
    'expected_subject_type', c.expected_subject_type,
    'is_system_generated', c.is_system_generated) order by c.domain, c.event_type), '[]'::jsonb)
  from public.activity_event_catalog c;
$$;

revoke all on function public.activity_event_catalog() from public, anon;
grant execute on function public.activity_event_catalog() to authenticated, service_role;

comment on function public.activity_event_catalog() is
  'R.2S.8: catálogo de tipos de activity con dominio y si son generados por el sistema.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smoke — _smoke_r2s_activity_catalog
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_r2s_activity_catalog()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  v_ctx uuid; v_casa uuid;
  v_uncatalogued integer;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José R2S-act', '+5210000081');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Contexto R2S activity', 'collective', 'friend_group'))->>'context_actor_id';
  v_casa := (public.create_resource(v_ctx::uuid, 'house', 'Casa R2S-act'))->>'resource_id';
  perform public.record_expense(v_ctx::uuid, 100, 'MXN', 'Gasto R2S-act');

  -- ═══ 1. Toda la activity producida está catalogada (ninguna uncatalogued) ═══
  select count(*) into v_uncatalogued
    from public.activity_events
   where context_actor_id = v_ctx::uuid
     and (payload->>'uncatalogued')::boolean is true;
  if v_uncatalogued <> 0 then
    raise exception 'R2S.8 FAIL 1: % eventos quedaron fuera del catálogo: %',
      v_uncatalogued,
      (select string_agg(distinct event_type, ', ') from public.activity_events
        where context_actor_id = v_ctx::uuid and (payload->>'uncatalogued')::boolean is true);
  end if;

  -- ═══ 2. Cada event_type producido existe en el catálogo ═══
  if exists (
    select 1 from public.activity_events ae
    where ae.context_actor_id = v_ctx::uuid
      and not exists (select 1 from public.activity_event_catalog c where c.event_type = ae.event_type)
  ) then
    raise exception 'R2S.8 FAIL 2: hay event_type producido sin entrada en el catálogo';
  end if;

  -- ═══ 3. Un tipo custom.* se permite (no se marca uncatalogued) ═══
  perform public._emit_activity(v_ctx::uuid, a_jose, 'custom.r2s_demo', 'actor', a_jose, '{}'::jsonb);
  if (select (payload->>'uncatalogued')::boolean from public.activity_events
        where context_actor_id = v_ctx::uuid and event_type = 'custom.r2s_demo') is true then
    raise exception 'R2S.8 FAIL 3: un custom.* fue marcado uncatalogued';
  end if;

  -- ═══ 4. Un tipo arbitrario no catalogado SÍ se marca uncatalogued ═══
  perform public._emit_activity(v_ctx::uuid, a_jose, 'totally.bogus_type', 'actor', a_jose, '{}'::jsonb);
  if (select (payload->>'uncatalogued')::boolean from public.activity_events
        where context_actor_id = v_ctx::uuid and event_type = 'totally.bogus_type') is not true then
    raise exception 'R2S.8 FAIL 4: un tipo arbitrario no fue marcado uncatalogued';
  end if;

  -- ═══ 5. activity_event_catalog() devuelve el catálogo ═══
  if jsonb_array_length(public.activity_event_catalog()) < 30 then
    raise exception 'R2S.8 FAIL 5: el catálogo de activity está incompleto';
  end if;

  -- ═══ 6. list_activity devuelve timeline reconstruible ═══
  if jsonb_array_length((public.list_activity(v_ctx::uuid))->'activity') < 1 then
    raise exception 'R2S.8 FAIL 6: list_activity no devuelve timeline';
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose], array[u_jose]);

  raise notice 'R.2S.8 ACTIVITY CATALOG: PASS (todo catalogado, custom.* permitido, tipo arbitrario marcado, timeline reconstruible)';
end; $$;

revoke all on function public._smoke_r2s_activity_catalog() from public, anon, authenticated;

create or replace function public._smoke_mvp2_r2s_activity_catalog()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_r2s_activity_catalog(); end; $$;
revoke all on function public._smoke_mvp2_r2s_activity_catalog() from public, anon, authenticated;
comment on function public._smoke_mvp2_r2s_activity_catalog() is 'Wrapper CI del smoke R.2S.8 activity catalog.';
