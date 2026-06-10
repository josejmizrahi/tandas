-- ============================================================================
-- R.9.A — ACTIVITY GAP CLOSURE (2026-06-11)
-- ============================================================================
-- Cierra el hueco de auditoría: varios RPCs mutantes recientes NO emitían
-- activity vía el gateway _emit_activity, dejando el timeline incompleto.
--
-- RPCs redefinidos (CREATE OR REPLACE, firma/comportamiento/grants intactos —
-- SOLO se agrega la emisión de activity + conteo de filas donde hace falta):
--   · add_event_guest / remove_event_guest        (r5z 20260610190000)
--   · add_event_participants /
--     remove_event_participants /
--     set_event_participant_plus_one              (r5z 20260610170000)
--   · set_event_participant_plus_count            (r5z 20260610180000)
--   · host_confirm_participant                    (r5z 20260610200000)
--   · dismiss_attention_item                      (r5z 20260609220000)
--   · claim_placeholder_actor                     (r5w 20260608220000 — emite UN
--       evento con conteos de reasignación por dominio en payload.reassigned)
--
-- Tipos nuevos catalogados en activity_event_catalog (siguiendo la taxonomía
-- canónica existente — participio pasado, dominio.sujeto):
--   event.guest_added · event.guest_removed · event.participants_added ·
--   event.participants_removed · event.participant_plus_updated (cubre
--   plus_one y plus_count) · event.participant_host_confirmed ·
--   attention.dismissed · membership.placeholder_claimed
--
-- Además se cataloga 'membership.placeholder_created' (r5w slice 1 lo emite
-- desde 20260608210000 pero nunca se registró — quedaba uncatalogued).
--
-- Smoke CI: _smoke_mvp2_r9_a_activity_coverage()
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Activity catalog: registrar los tipos nuevos
-- ────────────────────────────────────────────────────────────────────────────
insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('event.guest_added',                'event',      'Se agregó un invitado externo a un evento',          'calendar_event', false),
  ('event.guest_removed',              'event',      'Se quitó un invitado externo de un evento',          'calendar_event', false),
  ('event.participants_added',         'event',      'Se agregaron participantes al roster de un evento',  'calendar_event', false),
  ('event.participants_removed',       'event',      'Se quitaron participantes del roster de un evento',  'calendar_event', false),
  ('event.participant_plus_updated',   'event',      'Un participante actualizó sus acompañantes (+N)',    'calendar_event', false),
  ('event.participant_host_confirmed', 'event',      'El host confirmó a un participante en su nombre',    'calendar_event', false),
  ('attention.dismissed',              'attention',  'Se descartó un attention item',                      'attention_item', false),
  ('membership.placeholder_claimed',   'membership', 'Un placeholder fue reclamado por un usuario real',   'actor',          false),
  -- r5w slice 1 emite este tipo desde 20260608210000 pero nunca se catalogó:
  ('membership.placeholder_created',   'membership', 'Se creó un placeholder en el contexto',              'membership',     false),
  -- r5z appeal emite este tipo desde 20260610230000 pero nunca se catalogó:
  ('settlement.payment_appealed',      'settlement', 'El deudor apeló un pago de liquidación',             'settlement_item', false)
on conflict (event_type) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. add_event_guest — emite event.guest_added
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.add_event_guest(
  p_event_id uuid,
  p_display_name text,
  p_count_share int default 1,
  p_linked_actor_id uuid default null,
  p_source text default 'manual'
) returns jsonb
language plpgsql security definer set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
  v_is_participant boolean;
  v_guest_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if length(trim(coalesce(p_display_name, ''))) = 0 then
    raise exception 'display_name is required' using errcode = '22023';
  end if;
  if p_count_share is null or p_count_share < 1 or p_count_share > 20 then
    raise exception 'count_share must be between 1 and 20' using errcode = '22023';
  end if;
  if p_source not in ('manual','actor','contact') then
    raise exception 'invalid source' using errcode = '22023';
  end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot add guests to a terminal event' using errcode = '22023';
  end if;
  select exists (
    select 1 from public.event_participants
    where event_id = p_event_id
      and participant_actor_id = v_caller
      and status not in ('cancelled','declined')
  ) into v_is_participant;
  if not v_is_participant
     and v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (solo participants/host/admin pueden agregar invitados)' using errcode = '42501';
  end if;
  insert into public.event_guests
    (event_id, display_name, count_share, invited_by_actor_id, linked_actor_id, source)
  values
    (p_event_id, trim(p_display_name), p_count_share, v_caller, p_linked_actor_id, p_source)
  returning id into v_guest_id;

  -- R.9.A: auditoría
  perform public._emit_activity(
    v_ev.context_actor_id, v_caller, 'event.guest_added',
    'calendar_event', p_event_id,
    jsonb_build_object(
      'guest_id', v_guest_id,
      'display_name', trim(p_display_name),
      'count_share', p_count_share,
      'linked_actor_id', p_linked_actor_id,
      'source', p_source));

  return jsonb_build_object(
    'guest_id', v_guest_id, 'event_id', p_event_id,
    'display_name', trim(p_display_name), 'count_share', p_count_share,
    'invited_by', v_caller
  );
end;
$function$;

grant execute on function public.add_event_guest(uuid, text, int, uuid, text) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. remove_event_guest — emite event.guest_removed
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.remove_event_guest(p_guest_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_guest public.event_guests%rowtype;
  v_ev public.calendar_events%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_guest from public.event_guests where id = p_guest_id;
  if v_guest.id is null then raise exception 'guest not found' using errcode = 'P0002'; end if;
  if v_guest.removed_at is not null then
    return jsonb_build_object('changed', false, 'noop', true);
  end if;
  select * into v_ev from public.calendar_events where id = v_guest.event_id;
  if v_guest.invited_by_actor_id <> v_caller
     and v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized to remove this guest' using errcode = '42501';
  end if;
  update public.event_guests set removed_at = now() where id = p_guest_id;

  -- R.9.A: auditoría
  perform public._emit_activity(
    v_ev.context_actor_id, v_caller, 'event.guest_removed',
    'calendar_event', v_guest.event_id,
    jsonb_build_object(
      'guest_id', p_guest_id,
      'display_name', v_guest.display_name,
      'count_share', v_guest.count_share));

  return jsonb_build_object('changed', true, 'guest_id', p_guest_id);
end;
$function$;

grant execute on function public.remove_event_guest(uuid) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. add_event_participants — emite event.participants_added (solo si added > 0)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.add_event_participants(
  p_event_id uuid,
  p_actor_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
  v_added int := 0;
  v_actor_id uuid;
  v_added_ids uuid[] := array[]::uuid[];
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot edit participants of a terminal event' using errcode = '22023';
  end if;
  if v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (host o events.manage)' using errcode = '42501';
  end if;

  foreach v_actor_id in array p_actor_ids loop
    if not exists (
      select 1 from public.actor_memberships
      where context_actor_id = v_ev.context_actor_id
        and member_actor_id = v_actor_id
        and membership_status = 'active'
    ) then
      continue;
    end if;
    insert into public.event_participants (event_id, participant_actor_id, status)
    values (p_event_id, v_actor_id, 'invited')
    on conflict do nothing;
    if found then
      v_added := v_added + 1;
      v_added_ids := array_append(v_added_ids, v_actor_id);
    end if;
  end loop;

  -- R.9.A: auditoría (solo si hubo cambio real)
  if v_added > 0 then
    perform public._emit_activity(
      v_ev.context_actor_id, v_caller, 'event.participants_added',
      'calendar_event', p_event_id,
      jsonb_build_object('added', v_added, 'participant_actor_ids', to_jsonb(v_added_ids)));
  end if;

  return jsonb_build_object('added', v_added);
end;
$function$;

grant execute on function public.add_event_participants(uuid, uuid[]) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. remove_event_participants — emite event.participants_removed (si removed > 0)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.remove_event_participants(
  p_event_id uuid,
  p_actor_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
  v_removed int;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot edit participants of a terminal event' using errcode = '22023';
  end if;
  if v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (host o events.manage)' using errcode = '42501';
  end if;

  update public.event_participants
  set status = 'cancelled',
      cancelled_at = now()
  where event_id = p_event_id
    and participant_actor_id = any(p_actor_ids)
    and status not in ('cancelled');

  get diagnostics v_removed = row_count;

  -- R.9.A: auditoría (solo si hubo cambio real)
  if v_removed > 0 then
    perform public._emit_activity(
      v_ev.context_actor_id, v_caller, 'event.participants_removed',
      'calendar_event', p_event_id,
      jsonb_build_object('removed', v_removed, 'requested_actor_ids', to_jsonb(p_actor_ids)));
  end if;

  return jsonb_build_object('removed', v_removed);
end;
$function$;

grant execute on function public.remove_event_participants(uuid, uuid[]) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. set_event_participant_plus_one — emite event.participant_plus_updated
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.set_event_participant_plus_one(
  p_event_id uuid,
  p_actor_id uuid,
  p_plus_one boolean
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot edit a terminal event' using errcode = '22023';
  end if;
  if p_actor_id <> v_caller
     and v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (solo el participant, host o admin)' using errcode = '42501';
  end if;

  update public.event_participants
  set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('plus_one', p_plus_one)
  where event_id = p_event_id
    and participant_actor_id = p_actor_id;

  if not found then
    raise exception 'participant not found in event' using errcode = 'P0002';
  end if;

  -- R.9.A: auditoría (mismo event_type que plus_count — es la misma intención)
  perform public._emit_activity(
    v_ev.context_actor_id, v_caller, 'event.participant_plus_updated',
    'calendar_event', p_event_id,
    jsonb_build_object('participant_actor_id', p_actor_id, 'plus_one', p_plus_one));

  return jsonb_build_object('plus_one', p_plus_one);
end;
$function$;

grant execute on function public.set_event_participant_plus_one(uuid, uuid, boolean) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 7. set_event_participant_plus_count — emite event.participant_plus_updated
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.set_event_participant_plus_count(
  p_event_id uuid,
  p_actor_id uuid,
  p_count int
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_count is null or p_count < 0 or p_count > 20 then
    raise exception 'plus_count must be between 0 and 20' using errcode = '22023';
  end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot edit a terminal event' using errcode = '22023';
  end if;
  if p_actor_id <> v_caller
     and v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (solo el participant, host o admin)' using errcode = '42501';
  end if;

  update public.event_participants
  set metadata = coalesce(metadata, '{}'::jsonb)
                 - 'plus_one'
                 || jsonb_build_object('plus_count', p_count)
  where event_id = p_event_id
    and participant_actor_id = p_actor_id;

  if not found then
    raise exception 'participant not found in event' using errcode = 'P0002';
  end if;

  -- R.9.A: auditoría
  perform public._emit_activity(
    v_ev.context_actor_id, v_caller, 'event.participant_plus_updated',
    'calendar_event', p_event_id,
    jsonb_build_object('participant_actor_id', p_actor_id, 'plus_count', p_count));

  return jsonb_build_object('plus_count', p_count);
end;
$function$;

grant execute on function public.set_event_participant_plus_count(uuid, uuid, int) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 8. host_confirm_participant — emite event.participant_host_confirmed
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.host_confirm_participant(
  p_event_id uuid,
  p_actor_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_ev public.calendar_events%rowtype;
  v_caller_name text;
  v_event_title text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  select * into v_ev from public.calendar_events where id = p_event_id;
  if v_ev.id is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if v_ev.status in ('completed','cancelled') then
    raise exception 'cannot confirm participants of a terminal event' using errcode = '22023';
  end if;
  if v_ev.host_actor_id <> v_caller
     and not public.has_actor_authority(v_ev.context_actor_id, v_caller, 'events.manage') then
    raise exception 'not authorized (solo host o events.manage)' using errcode = '42501';
  end if;

  update public.event_participants
  set status = 'going',
      rsvp_at = coalesce(rsvp_at, now()),
      metadata = coalesce(metadata, '{}'::jsonb)
                 || jsonb_build_object(
                      'host_confirmed', true,
                      'host_confirmed_by', v_caller,
                      'host_confirmed_at', now()
                    )
  where event_id = p_event_id and participant_actor_id = p_actor_id;

  if not found then
    raise exception 'participant not in event' using errcode = 'P0002';
  end if;

  select display_name into v_caller_name from public.actors where id = v_caller;
  v_event_title := v_ev.title;

  insert into public.rule_attention_items
    (context_actor_id, subject_actor_id,
     kind, title, reason, priority,
     cta_action_key, cta_scope_kind, cta_scope_id,
     source_rule_id, source_event_id, idempotency_key, metadata)
  values
    (v_ev.context_actor_id, p_actor_id,
     'event_confirmation_by_host',
     format('%s te confirmó al evento %s', coalesce(v_caller_name, 'Alguien'), v_event_title),
     'Si no vas, cambia tu respuesta para no entrar en el split del gasto.',
     'normal',
     'rsvp_event',
     'event',
     p_event_id,
     null,
     null,
     'host_confirm:' || p_event_id::text || ':' || p_actor_id::text || ':' || extract(epoch from now())::text,
     jsonb_build_object('host_confirmed_by', v_caller, 'event_title', v_event_title))
  on conflict (idempotency_key) do nothing;

  -- R.9.A: auditoría
  perform public._emit_activity(
    v_ev.context_actor_id, v_caller, 'event.participant_host_confirmed',
    'calendar_event', p_event_id,
    jsonb_build_object(
      'participant_actor_id', p_actor_id,
      'confirmed_by_actor_id', v_caller,
      'status', 'going'));

  return jsonb_build_object(
    'changed', true,
    'event_id', p_event_id,
    'actor_id', p_actor_id,
    'status', 'going'
  );
end;
$function$;

grant execute on function public.host_confirm_participant(uuid, uuid) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 9. dismiss_attention_item — emite attention.dismissed
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.dismiss_attention_item(
  p_attention_item_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.rule_attention_items%rowtype;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select * into v_item
  from public.rule_attention_items
  where id = p_attention_item_id;

  if v_item.id is null then
    raise exception 'attention item not found' using errcode = 'P0002';
  end if;

  -- Idempotent: ya resuelto/descartado
  if v_item.status <> 'open' then
    return jsonb_build_object(
      'changed', false,
      'attention_item_id', p_attention_item_id,
      'status', v_item.status,
      'noop', true
    );
  end if;

  -- Auth: el subject del item O un admin del contexto pueden dismissear.
  if v_item.subject_actor_id <> v_caller
     and not public.has_actor_authority(v_item.context_actor_id, v_caller, 'rules.manage')
  then
    raise exception 'not authorized to dismiss this attention item'
      using errcode = '42501';
  end if;

  update public.rule_attention_items
  set status = 'dismissed',
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'dismissed_by', v_caller,
        'dismissed_at', now()
      )
  where id = p_attention_item_id;

  -- R.9.A: auditoría
  perform public._emit_activity(
    v_item.context_actor_id, v_caller, 'attention.dismissed',
    'attention_item', p_attention_item_id,
    jsonb_build_object(
      'kind', v_item.kind,
      'subject_actor_id', v_item.subject_actor_id,
      'cta_action_key', v_item.cta_action_key));

  return jsonb_build_object(
    'changed', true,
    'attention_item_id', p_attention_item_id,
    'status', 'dismissed'
  );
end;
$function$;

grant execute on function public.dismiss_attention_item(uuid) to authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 10. claim_placeholder_actor — emite membership.placeholder_claimed
-- ────────────────────────────────────────────────────────────────────────────
-- UN solo evento que resume el claim, con conteos de reasignación por dominio
-- en payload.reassigned (memberships / obligations / money_splits /
-- event_participants). El contexto del evento es el primer contexto donde el
-- placeholder tenía membership (capturado ANTES de reasignar; null si ninguno).
-- Nota: el return conserva EXACTO el shape original (obligations_reassigned
-- sigue contando solo el UPDATE de creditor, como en r5w slice 4); el conteo
-- fiel debtor+creditor vive en payload.reassigned.obligations.
CREATE OR REPLACE FUNCTION public.claim_placeholder_actor(p_placeholder_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
declare
  v_caller_actor uuid := public.current_actor_id();
  v_phone text;
  v_email text;
  v_placeholder record;
  v_matches boolean;
  v_membership_count int;
  v_obligation_debtor_count int;
  v_obligation_count int;
  v_split_count int;
  v_participant_count int;
  v_primary_context uuid;
begin
  if v_caller_actor is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  SELECT lower(btrim(phone)), lower(btrim(email))
    INTO v_phone, v_email
    FROM auth.users WHERE id = auth.uid();

  SELECT * INTO v_placeholder
    FROM public.actors WHERE id = p_placeholder_actor_id FOR UPDATE;

  if v_placeholder.id is null then
    raise exception 'placeholder not found' using errcode = 'P0002';
  end if;
  if v_placeholder.is_placeholder is not true then
    raise exception 'actor is not a placeholder' using errcode = '22023';
  end if;
  if v_placeholder.claimed_at is not null then
    raise exception 'placeholder already claimed' using errcode = '22023';
  end if;

  v_matches :=
    (v_phone is not null and v_phone <> '' and v_placeholder.contact_phone is not null
      and lower(btrim(v_placeholder.contact_phone)) = v_phone)
    OR
    (v_email is not null and v_email <> '' and v_placeholder.contact_email is not null
      and lower(btrim(v_placeholder.contact_email)) = v_email);

  if not v_matches then
    raise exception 'placeholder contact does not match your phone/email'
      using errcode = '42501';
  end if;

  -- R.9.A: contexto representativo para el evento de activity, capturado
  -- ANTES de tocar las memberships del placeholder.
  SELECT m.context_actor_id INTO v_primary_context
    FROM public.actor_memberships m
   WHERE m.member_actor_id = p_placeholder_actor_id
   ORDER BY m.joined_at ASC NULLS LAST, m.context_actor_id
   LIMIT 1;

  WITH conflict_contexts AS (
    SELECT m_p.context_actor_id
      FROM public.actor_memberships m_p
     WHERE m_p.member_actor_id = p_placeholder_actor_id
       AND EXISTS (
         SELECT 1 FROM public.actor_memberships m_c
          WHERE m_c.member_actor_id = v_caller_actor
            AND m_c.context_actor_id = m_p.context_actor_id
       )
  )
  DELETE FROM public.actor_memberships
   WHERE member_actor_id = p_placeholder_actor_id
     AND context_actor_id IN (SELECT context_actor_id FROM conflict_contexts);

  UPDATE public.actor_memberships SET member_actor_id = v_caller_actor
   WHERE member_actor_id = p_placeholder_actor_id;
  GET DIAGNOSTICS v_membership_count = ROW_COUNT;

  UPDATE public.obligations SET debtor_actor_id = v_caller_actor
   WHERE debtor_actor_id = p_placeholder_actor_id;
  GET DIAGNOSTICS v_obligation_debtor_count = ROW_COUNT;
  UPDATE public.obligations SET creditor_actor_id = v_caller_actor
   WHERE creditor_actor_id = p_placeholder_actor_id;
  GET DIAGNOSTICS v_obligation_count = ROW_COUNT;

  UPDATE public.money_splits SET actor_id = v_caller_actor
   WHERE actor_id = p_placeholder_actor_id;
  GET DIAGNOSTICS v_split_count = ROW_COUNT;

  WITH conflict_events AS (
    SELECT p_p.event_id
      FROM public.event_participants p_p
     WHERE p_p.participant_actor_id = p_placeholder_actor_id
       AND EXISTS (
         SELECT 1 FROM public.event_participants p_c
          WHERE p_c.participant_actor_id = v_caller_actor
            AND p_c.event_id = p_p.event_id
       )
  )
  DELETE FROM public.event_participants
   WHERE participant_actor_id = p_placeholder_actor_id
     AND event_id IN (SELECT event_id FROM conflict_events);

  UPDATE public.event_participants SET participant_actor_id = v_caller_actor
   WHERE participant_actor_id = p_placeholder_actor_id;
  GET DIAGNOSTICS v_participant_count = ROW_COUNT;

  UPDATE public.actors
     SET claimed_at = now(),
         claimed_by_actor_id = v_caller_actor,
         status = 'archived',
         archived_at = now()
   WHERE id = p_placeholder_actor_id;

  -- R.9.A: UN evento de activity que resume el claim completo.
  perform public._emit_activity(
    v_primary_context, v_caller_actor, 'membership.placeholder_claimed',
    'actor', p_placeholder_actor_id,
    jsonb_build_object(
      'placeholder_actor_id', p_placeholder_actor_id,
      'placeholder_display_name', v_placeholder.display_name,
      'claimed_by_actor_id', v_caller_actor,
      'reassigned', jsonb_build_object(
        'memberships', coalesce(v_membership_count, 0),
        'obligations', coalesce(v_obligation_debtor_count, 0) + coalesce(v_obligation_count, 0),
        'money_splits', coalesce(v_split_count, 0),
        'event_participants', coalesce(v_participant_count, 0))));

  return jsonb_build_object(
    'claimed_actor_id', p_placeholder_actor_id,
    'claimed_by_actor_id', v_caller_actor,
    'memberships_reassigned', coalesce(v_membership_count, 0),
    'obligations_reassigned', coalesce(v_obligation_count, 0),
    'splits_reassigned', coalesce(v_split_count, 0),
    'event_participants_reassigned', coalesce(v_participant_count, 0)
  );
end; $function$;

GRANT EXECUTE ON FUNCTION public.claim_placeholder_actor(uuid) TO authenticated;

-- ────────────────────────────────────────────────────────────────────────────
-- 11. Smoke CI — _smoke_mvp2_r9_a_activity_coverage
-- ────────────────────────────────────────────────────────────────────────────
-- Mundo: contexto con 2 miembros + 1 placeholder, 1 evento. Ejercita cada RPC
-- redefinido y asserta que activity_events creció con el event_type correcto.
create or replace function public._smoke_mvp2_r9_a_activity_coverage()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_host uuid := gen_random_uuid();
  u_member uuid := gen_random_uuid();
  u_claimer uuid := gen_random_uuid();
  a_host uuid; a_member uuid; a_claimer uuid; a_ph uuid;
  v_ctx uuid; v_code text; v_event uuid; v_guest uuid; v_attention uuid;
  v_result jsonb;
  v_payload jsonb;
  v_n int;
begin
  -- ═══ Mundo: contexto con 2 miembros + 1 placeholder + 1 evento ═══
  a_host := public._create_person_actor_for_auth_user(u_host, 'R9A Host', '+520000009001', null);
  a_member := public._create_person_actor_for_auth_user(u_member, 'R9A Member', '+520000009002', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r9a Cena', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text)::text, true);
  a_ph := ((public.create_placeholder_person(v_ctx, 'R9A Placeholder', '+520000009099', null))->>'actor_id')::uuid;

  v_event := ((public.create_calendar_event(
    v_ctx, '_smoke_r9a Evento', 'dinner',
    now() + interval '2 days', now() + interval '2 days 3 hours',
    p_invite_all_members := false))->>'event_id')::uuid;

  -- ═══ 1. add_event_participants → event.participants_added ═══
  v_result := public.add_event_participants(v_event, array[a_member, a_ph]);
  if (v_result->>'added')::int <> 2 then
    raise exception 'r9_a FAIL 1: add_event_participants esperaba added=2, fue %', v_result->>'added';
  end if;
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'event.participants_added' and subject_id = v_event;
  if v_n <> 1 then
    raise exception 'r9_a FAIL 1: esperaba 1 event.participants_added, encontré %', v_n;
  end if;

  -- ═══ 2. set_event_participant_plus_one → event.participant_plus_updated ═══
  perform public.set_event_participant_plus_one(v_event, a_member, true);
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'event.participant_plus_updated' and subject_id = v_event;
  if v_n <> 1 then
    raise exception 'r9_a FAIL 2: esperaba 1 event.participant_plus_updated tras plus_one, encontré %', v_n;
  end if;

  -- ═══ 3. set_event_participant_plus_count → event.participant_plus_updated ═══
  perform public.set_event_participant_plus_count(v_event, a_member, 3);
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'event.participant_plus_updated' and subject_id = v_event;
  if v_n <> 2 then
    raise exception 'r9_a FAIL 3: esperaba 2 event.participant_plus_updated tras plus_count, encontré %', v_n;
  end if;
  if not exists (select 1 from public.activity_events
                  where context_actor_id = v_ctx and event_type = 'event.participant_plus_updated'
                    and (payload->>'plus_count')::int = 3) then
    raise exception 'r9_a FAIL 3: el evento de plus_count no trae payload.plus_count=3';
  end if;

  -- ═══ 4. host_confirm_participant → event.participant_host_confirmed ═══
  perform public.host_confirm_participant(v_event, a_member);
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'event.participant_host_confirmed' and subject_id = v_event;
  if v_n <> 1 then
    raise exception 'r9_a FAIL 4: esperaba 1 event.participant_host_confirmed, encontré %', v_n;
  end if;

  -- ═══ 5. dismiss_attention_item → attention.dismissed (como subject) ═══
  select id into v_attention from public.rule_attention_items
   where context_actor_id = v_ctx and subject_actor_id = a_member
     and kind = 'event_confirmation_by_host' and status = 'open'
   limit 1;
  if v_attention is null then
    raise exception 'r9_a FAIL 5: host_confirm_participant no creó el attention item';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text)::text, true);
  perform public.dismiss_attention_item(v_attention);
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'attention.dismissed' and subject_id = v_attention;
  if v_n <> 1 then
    raise exception 'r9_a FAIL 5: esperaba 1 attention.dismissed, encontré %', v_n;
  end if;

  -- ═══ 6. add_event_guest → event.guest_added ═══
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text)::text, true);
  v_guest := ((public.add_event_guest(v_event, 'Primo R9A', 2))->>'guest_id')::uuid;
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'event.guest_added' and subject_id = v_event;
  if v_n <> 1 then
    raise exception 'r9_a FAIL 6: esperaba 1 event.guest_added, encontré %', v_n;
  end if;

  -- ═══ 7. remove_event_guest → event.guest_removed ═══
  perform public.remove_event_guest(v_guest);
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'event.guest_removed' and subject_id = v_event;
  if v_n <> 1 then
    raise exception 'r9_a FAIL 7: esperaba 1 event.guest_removed, encontré %', v_n;
  end if;

  -- ═══ 8. remove_event_participants → event.participants_removed ═══
  v_result := public.remove_event_participants(v_event, array[a_member]);
  if (v_result->>'removed')::int <> 1 then
    raise exception 'r9_a FAIL 8: remove_event_participants esperaba removed=1, fue %', v_result->>'removed';
  end if;
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'event.participants_removed' and subject_id = v_event;
  if v_n <> 1 then
    raise exception 'r9_a FAIL 8: esperaba 1 event.participants_removed, encontré %', v_n;
  end if;

  -- ═══ 9. claim_placeholder_actor → membership.placeholder_claimed ═══
  -- El claimer se registra con el MISMO phone del placeholder (match implícito).
  perform set_config('request.jwt.claims', null, true);
  insert into auth.users (id, instance_id, aud, role, phone, raw_user_meta_data, created_at, updated_at)
  values (u_claimer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          '+520000009099', '{"full_name": "R9A Claimer"}'::jsonb, now(), now());
  select actor_id into a_claimer from public.person_profiles where auth_user_id = u_claimer;
  if a_claimer is null then
    raise exception 'r9_a FAIL 9: el trigger de auth no creó el actor del claimer';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_claimer::text)::text, true);
  v_result := public.claim_placeholder_actor(a_ph);
  if (v_result->>'memberships_reassigned')::int <> 1 then
    raise exception 'r9_a FAIL 9: claim esperaba memberships_reassigned=1, fue %', v_result->>'memberships_reassigned';
  end if;
  if (v_result->>'event_participants_reassigned')::int <> 1 then
    raise exception 'r9_a FAIL 9: claim esperaba event_participants_reassigned=1, fue %', v_result->>'event_participants_reassigned';
  end if;

  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and event_type = 'membership.placeholder_claimed' and subject_id = a_ph;
  if v_n <> 1 then
    raise exception 'r9_a FAIL 9: esperaba 1 membership.placeholder_claimed en el contexto, encontré %', v_n;
  end if;

  select payload into v_payload from public.activity_events
   where context_actor_id = v_ctx and event_type = 'membership.placeholder_claimed' and subject_id = a_ph;
  if (v_payload->'reassigned'->>'memberships')::int <> 1 then
    raise exception 'r9_a FAIL 9: payload.reassigned.memberships esperaba 1, fue %', v_payload->'reassigned'->>'memberships';
  end if;
  if (v_payload->'reassigned'->>'event_participants')::int <> 1 then
    raise exception 'r9_a FAIL 9: payload.reassigned.event_participants esperaba 1, fue %', v_payload->'reassigned'->>'event_participants';
  end if;
  if (v_payload->'reassigned'->>'obligations')::int <> 0 then
    raise exception 'r9_a FAIL 9: payload.reassigned.obligations esperaba 0, fue %', v_payload->'reassigned'->>'obligations';
  end if;
  if (v_payload->'reassigned'->>'money_splits')::int <> 0 then
    raise exception 'r9_a FAIL 9: payload.reassigned.money_splits esperaba 0, fue %', v_payload->'reassigned'->>'money_splits';
  end if;

  -- ═══ 10. Ningún tipo emitido quedó fuera del catálogo ═══
  select count(*) into v_n from public.activity_events
   where context_actor_id = v_ctx and (payload->>'uncatalogued')::boolean is true;
  if v_n <> 0 then
    raise exception 'r9_a FAIL 10: % eventos quedaron uncatalogued: %', v_n,
      (select string_agg(distinct event_type, ', ') from public.activity_events
        where context_actor_id = v_ctx and (payload->>'uncatalogued')::boolean is true);
  end if;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx, array[a_host, a_member, a_ph, a_claimer], array[u_host, u_member, u_claimer]);

  raise notice 'R.9.A ACTIVITY GAP CLOSURE: PASS (guests + participants + plus + host_confirm + attention + claim emiten activity catalogada)';
end; $$;

revoke all on function public._smoke_mvp2_r9_a_activity_coverage() from public, anon, authenticated;

comment on function public._smoke_mvp2_r9_a_activity_coverage() is
  'R.9.A DoD: todos los RPCs mutantes redefinidos emiten activity catalogada (event.guest_* / event.participants_* / event.participant_plus_updated / event.participant_host_confirmed / attention.dismissed / membership.placeholder_claimed).';
