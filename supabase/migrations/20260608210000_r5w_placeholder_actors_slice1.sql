-- R.5W.placeholder Slice 1 (2026-06-08) — placeholder actors para invitar
-- personas que no usan la app (caso Splitwise: abuela, tío, vecino).
--
-- Doctrina: un placeholder actor es de primera clase — aparece en
-- members list, puede recibir splits/obligaciones/RSVPs. NO tiene
-- person_profile (auth_user_id NOT NULL bloquea), su info de contacto
-- vive directo en actors para futura matching/claim.

ALTER TABLE public.actors
  ADD COLUMN IF NOT EXISTS is_placeholder boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS contact_phone text,
  ADD COLUMN IF NOT EXISTS contact_email text,
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz;

-- Indexes para lookup en futuro claim flow (Slice 4). No UNIQUE porque
-- una persona puede ser placeholder en varios contextos antes de registrarse.
CREATE INDEX IF NOT EXISTS actors_placeholder_phone_idx
  ON public.actors(lower(contact_phone))
  WHERE is_placeholder = true AND contact_phone IS NOT NULL;

CREATE INDEX IF NOT EXISTS actors_placeholder_email_idx
  ON public.actors(lower(contact_email))
  WHERE is_placeholder = true AND contact_email IS NOT NULL;

COMMENT ON COLUMN public.actors.is_placeholder IS
  'R.5W: true = persona real sin auth (creada por miembro del contexto). Aparece en members/splits/eventos. Slice 4 agregará claim flow.';
COMMENT ON COLUMN public.actors.contact_phone IS
  'R.5W: phone para futura matching cuando la persona se registre. Sin validación E.164 en v1.';
COMMENT ON COLUMN public.actors.contact_email IS
  'R.5W: email para futura matching cuando la persona se registre.';
COMMENT ON COLUMN public.actors.claimed_at IS
  'R.5W: timestamp cuando placeholder fue fusionado con user real (Slice 4).';

-- RPC: create_placeholder_person
-- Auth: 'context.invite' authority sobre el contexto destino (mismo gate
-- que create_invite/invite_member).
-- Crea actor (kind=person, subtype=person, is_placeholder=true) +
-- membership active. Emite activity 'membership.placeholder_created'.
CREATE OR REPLACE FUNCTION public.create_placeholder_person(
  p_context_actor_id uuid,
  p_display_name text,
  p_phone text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_membership_type text DEFAULT 'member'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
declare
  v_caller uuid := public.current_actor_id();
  v_actor_id uuid;
  v_membership_id uuid;
  v_name text;
  v_phone text;
  v_email text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'context.invite') then
    raise exception 'not authorized to invite to context %', p_context_actor_id using errcode = '42501';
  end if;

  v_name  := nullif(btrim(p_display_name), '');
  v_phone := nullif(btrim(coalesce(p_phone, '')), '');
  v_email := nullif(lower(btrim(coalesce(p_email, ''))), '');

  if v_name is null then
    raise exception 'display_name is required' using errcode = '22023';
  end if;

  -- Crear actor placeholder (kind=person/subtype=person, is_placeholder=true).
  insert into public.actors (
    actor_kind, actor_subtype, display_name, status, visibility,
    metadata, created_by_actor_id, is_context,
    is_placeholder, contact_phone, contact_email
  ) values (
    'person', 'person', v_name, 'active', 'private',
    '{}'::jsonb, v_caller, false,
    true, v_phone, v_email
  )
  returning id into v_actor_id;

  -- Membership activa inmediata (no 'invited' — el placeholder ya está "adentro").
  insert into public.actor_memberships (
    context_actor_id, member_actor_id, membership_status, membership_type,
    invited_by_actor_id, joined_at
  ) values (
    p_context_actor_id, v_actor_id, 'active', coalesce(p_membership_type, 'member'),
    v_caller, now()
  )
  returning id into v_membership_id;

  -- Activity para auditoría + futuras attentions.
  perform public._emit_activity(
    p_context_actor_id, v_caller,
    'membership.placeholder_created', 'membership', v_membership_id,
    jsonb_build_object(
      'placeholder_actor_id', v_actor_id,
      'display_name', v_name,
      'has_phone', v_phone is not null,
      'has_email', v_email is not null
    )
  );

  return jsonb_build_object(
    'actor_id', v_actor_id,
    'membership_id', v_membership_id,
    'display_name', v_name,
    'is_placeholder', true,
    'contact_phone', v_phone,
    'contact_email', v_email
  );
end; $function$;

GRANT EXECUTE ON FUNCTION public.create_placeholder_person(uuid, text, text, text, text) TO authenticated;
