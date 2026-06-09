-- R.5W.placeholder Slice 4 (2026-06-08) — claim/merge cuando placeholder
-- se registra. Doctrina founder-signed:
--
-- 1. Match implícito por phone/email (vs auth.users). NO auto-merge — el
--    usuario confirma con sheet "Reclamar invitaciones pendientes".
-- 2. Merge atómico: reasigna FKs (memberships, obligations, splits, event
--    participants) del placeholder → user real. Maneja conflictos si el
--    user ya es miembro del mismo contexto (DELETE el row del placeholder
--    porque el user ya tiene su propia membership).
-- 3. Mark placeholder con claimed_at + claimed_by_actor_id + status=archived
--    — el row queda como tombstone para trazabilidad.

ALTER TABLE public.actors
  ADD COLUMN IF NOT EXISTS claimed_by_actor_id uuid REFERENCES public.actors(id);

COMMENT ON COLUMN public.actors.claimed_by_actor_id IS
  'R.5W Slice 4: actor real que reclamó este placeholder al registrarse.';


CREATE OR REPLACE FUNCTION public.find_placeholder_matches_for_me()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
declare
  v_caller_actor uuid := public.current_actor_id();
  v_phone text;
  v_email text;
begin
  if v_caller_actor is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  SELECT lower(btrim(phone)), lower(btrim(email))
    INTO v_phone, v_email
    FROM auth.users WHERE id = auth.uid();

  if (v_phone is null or v_phone = '') and (v_email is null or v_email = '') then
    return jsonb_build_object('matches', '[]'::jsonb, 'reason', 'no_contact_info');
  end if;

  return jsonb_build_object(
    'matches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'actor_id', a.id,
        'display_name', a.display_name,
        'contact_phone', a.contact_phone,
        'contact_email', a.contact_email,
        'context_count', (
          select count(*) from public.actor_memberships m
          where m.member_actor_id = a.id and m.membership_status = 'active'
        ),
        'contexts', coalesce((
          select jsonb_agg(jsonb_build_object(
            'context_actor_id', ca.id,
            'context_display_name', ca.display_name,
            'context_actor_subtype', ca.actor_subtype
          ))
          from public.actor_memberships m
          join public.actors ca on ca.id = m.context_actor_id
          where m.member_actor_id = a.id and m.membership_status = 'active'
        ), '[]'::jsonb)
      ))
      from public.actors a
      where a.is_placeholder = true
        and a.claimed_at is null
        and (
          (v_phone <> '' and a.contact_phone is not null
            and lower(btrim(a.contact_phone)) = v_phone)
          or
          (v_email <> '' and a.contact_email is not null
            and lower(btrim(a.contact_email)) = v_email)
        )
    ), '[]'::jsonb)
  );
end; $function$;

GRANT EXECUTE ON FUNCTION public.find_placeholder_matches_for_me() TO authenticated;


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
  v_obligation_count int;
  v_split_count int;
  v_participant_count int;
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
