-- R.14.D — Reputación opt-out por grupo.
--
-- Friend Groups Launch, riesgo de producto #2 (severidad Alta, ambas
-- auditorías 2026-06-21 acordaron subirlo a P0): "Hall of Shame ofende →
-- grupos abandonan". Hoy la reputación (leaderboards + score por miembro)
-- es visible siempre y no hay forma de apagarla.
--
-- Solución mínima (first principles — un solo punto de enforcement):
--   1. `update_context` gana el slot `members_config` (deep merge, mismo
--      patrón que decisions/money/reservations/invitations).
--   2. `context_settings_summary` proyecta `members_config.show_reputation`
--      (default true — opt-out, no opt-in).
--   3. `list_context_members_with_reputation` devuelve `[]` cuando el grupo
--      apagó la reputación. iOS ya oculta leaderboards, badges y la sección
--      de detalle cuando no hay datos — cero lógica duplicada en cliente.
--
-- Permisos: el toggle requiere context.manage (mismo gate que el resto de
-- update_context). La lectura respeta membership active como antes.

-- 1. update_context — nueva firma con p_members_config.
--    DROP explícito: agregar un parámetro via CREATE OR REPLACE crearía un
--    overload y PostgREST fallaría por ambigüedad.
DROP FUNCTION IF EXISTS public.update_context(uuid, text, text, text, text, jsonb, jsonb, jsonb, jsonb);

CREATE FUNCTION public.update_context(
  p_context_actor_id uuid,
  p_display_name text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_visibility text DEFAULT NULL,
  p_image_url text DEFAULT NULL,
  p_decisions_config jsonb DEFAULT NULL,
  p_money_config jsonb DEFAULT NULL,
  p_reservations_config jsonb DEFAULT NULL,
  p_invitations_config jsonb DEFAULT NULL,
  p_members_config jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_actor public.actors%rowtype;
  v_meta jsonb;
  v_fields_changed text[] := ARRAY[]::text[];
  v_new_display_name text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;

  SELECT * INTO v_actor FROM public.actors WHERE id = p_context_actor_id;
  IF v_actor.id IS NULL THEN
    RAISE EXCEPTION 'context not found' USING errcode = 'P0002';
  END IF;
  IF v_actor.actor_kind = 'person' THEN
    RAISE EXCEPTION 'cannot update personal context via update_context (use update_my_profile)' USING errcode = '22023';
  END IF;
  IF NOT public.has_actor_authority(p_context_actor_id, v_caller, 'context.manage') THEN
    RAISE EXCEPTION 'context.manage required to edit context %', p_context_actor_id USING errcode = '42501';
  END IF;

  -- Validate visibility against actors_visibility_check.
  IF p_visibility IS NOT NULL AND p_visibility NOT IN ('private', 'members', 'public') THEN
    RAISE EXCEPTION 'invalid visibility "%" (allowed: private, members, public)', p_visibility USING errcode = '22023';
  END IF;

  -- Validate display_name not empty when provided.
  IF p_display_name IS NOT NULL THEN
    v_new_display_name := btrim(p_display_name);
    IF v_new_display_name = '' THEN
      RAISE EXCEPTION 'display_name cannot be empty' USING errcode = '22023';
    END IF;
  END IF;

  v_meta := COALESCE(v_actor.metadata, '{}'::jsonb);

  -- Top-level metadata slots (overwrite).
  IF p_description IS NOT NULL THEN
    v_meta := v_meta || jsonb_build_object('description', p_description);
    v_fields_changed := v_fields_changed || ARRAY['description'];
  END IF;
  IF p_image_url IS NOT NULL THEN
    v_meta := v_meta || jsonb_build_object('image_url', p_image_url);
    v_fields_changed := v_fields_changed || ARRAY['image_url'];
  END IF;

  -- Nested configs (deep merge: existing slot overlaid with new keys).
  IF p_decisions_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{decisions_config}',
      COALESCE(v_meta->'decisions_config', '{}'::jsonb) || p_decisions_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['decisions_config'];
  END IF;
  IF p_money_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{money_config}',
      COALESCE(v_meta->'money_config', '{}'::jsonb) || p_money_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['money_config'];
  END IF;
  IF p_reservations_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{reservations_config}',
      COALESCE(v_meta->'reservations_config', '{}'::jsonb) || p_reservations_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['reservations_config'];
  END IF;
  IF p_invitations_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{invitations_config}',
      COALESCE(v_meta->'invitations_config', '{}'::jsonb) || p_invitations_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['invitations_config'];
  END IF;
  IF p_members_config IS NOT NULL THEN
    v_meta := jsonb_set(
      v_meta, '{members_config}',
      COALESCE(v_meta->'members_config', '{}'::jsonb) || p_members_config,
      true);
    v_fields_changed := v_fields_changed || ARRAY['members_config'];
  END IF;

  IF p_display_name IS NOT NULL THEN
    v_fields_changed := v_fields_changed || ARRAY['display_name'];
  END IF;
  IF p_visibility IS NOT NULL THEN
    v_fields_changed := v_fields_changed || ARRAY['visibility'];
  END IF;

  -- Si nada cambió, devolver el summary actual sin escritura ni emisión.
  IF array_length(v_fields_changed, 1) IS NULL THEN
    RETURN public.context_settings_summary(p_context_actor_id);
  END IF;

  UPDATE public.actors
     SET display_name = COALESCE(v_new_display_name, display_name),
         visibility   = COALESCE(p_visibility, visibility),
         metadata     = v_meta,
         updated_at   = now()
   WHERE id = p_context_actor_id;

  PERFORM public._emit_activity(
    p_context_actor_id, v_caller, 'context.updated', 'context', p_context_actor_id,
    jsonb_build_object('fields_changed', to_jsonb(v_fields_changed))
  );

  RETURN public.context_settings_summary(p_context_actor_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_context(uuid, text, text, text, text, jsonb, jsonb, jsonb, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_context(uuid, text, text, text, text, jsonb, jsonb, jsonb, jsonb, jsonb) TO authenticated, service_role;

COMMENT ON FUNCTION public.update_context(uuid, text, text, text, text, jsonb, jsonb, jsonb, jsonb, jsonb) IS
'F.1A polish + R.14.D — write path para context_settings_summary slots (display_name, visibility, description, image_url, decisions_config, money_config, reservations_config, invitations_config, members_config). Permission gate: context.manage. Deep merge en nested configs. Retorna context_settings_summary(...) para refresh inmediato.';

-- 2. context_settings_summary — proyecta members_config.show_reputation.
CREATE OR REPLACE FUNCTION public.context_settings_summary(p_context_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_caller uuid := public.current_actor_id();
  v_actor public.actors%rowtype;
  v_meta jsonb;
  v_member_count int;
  v_can_manage boolean;
  v_can_manage_members boolean;
  v_can_manage_rules boolean;
  v_can_invite boolean;
  v_can_view boolean;
  v_actions jsonb := '[]'::jsonb;
BEGIN
  IF v_caller IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING errcode = '28000'; END IF;

  SELECT * INTO v_actor FROM public.actors WHERE id = p_context_actor_id;
  IF v_actor.id IS NULL THEN
    RAISE EXCEPTION 'context not found' USING errcode = 'P0002';
  END IF;
  IF v_actor.actor_kind = 'person' THEN
    RAISE EXCEPTION 'personal contexts have no settings (use personal_settings_summary)' USING errcode = '22023';
  END IF;
  IF NOT public.is_context_member(p_context_actor_id) THEN
    RAISE EXCEPTION 'not a member of context' USING errcode = '42501';
  END IF;

  v_meta := COALESCE(v_actor.metadata, '{}'::jsonb);

  SELECT count(*) INTO v_member_count
    FROM public.actor_memberships
   WHERE context_actor_id = p_context_actor_id AND membership_status = 'active';

  v_can_view          := public.has_actor_authority(p_context_actor_id, v_caller, 'context.view');
  v_can_manage        := public.has_actor_authority(p_context_actor_id, v_caller, 'context.manage');
  v_can_manage_members:= public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage');
  v_can_manage_rules  := public.has_actor_authority(p_context_actor_id, v_caller, 'rules.manage');
  v_can_invite        := public.has_actor_authority(p_context_actor_id, v_caller, 'context.invite');

  IF v_can_manage THEN
    v_actions := v_actions
      || '["edit_general","edit_decisions","edit_money","edit_reservations","edit_invitations","view_audit"]'::jsonb;
  END IF;
  IF v_can_manage_members THEN
    v_actions := v_actions || '["manage_members","manage_roles"]'::jsonb;
  END IF;
  IF v_can_manage_rules THEN
    v_actions := v_actions || '["manage_rules"]'::jsonb;
  END IF;
  IF v_can_invite THEN
    v_actions := v_actions || '["create_invite"]'::jsonb;
  END IF;
  IF v_can_view THEN
    v_actions := v_actions || '["view"]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'context_actor_id', p_context_actor_id,
    'general', jsonb_build_object(
      'display_name', v_actor.display_name,
      'description',  v_meta->>'description',
      'subtype',      v_actor.actor_subtype,
      'visibility',   v_actor.visibility,
      'member_count', v_member_count,
      'image_url',    v_meta->>'image_url'
    ),
    'decisions_config', jsonb_build_object(
      'default_voting_model', COALESCE(v_meta->'decisions_config'->>'default_voting_model', 'yes_no_abstain'),
      'quorum',               COALESCE(v_meta->'decisions_config'->>'quorum', 'simple_majority'),
      'majority_rule',        COALESCE(v_meta->'decisions_config'->>'majority_rule', 'simple')
    ),
    'money_config', jsonb_build_object(
      'currency',           COALESCE(v_meta->'money_config'->>'currency', 'MXN'),
      'default_split',      COALESCE(v_meta->'money_config'->>'default_split', 'equal'),
      'settlement_policy',  COALESCE(v_meta->'money_config'->>'settlement_policy', 'monthly')
    ),
    'reservations_config', jsonb_build_object(
      'priority_policy',       COALESCE(v_meta->'reservations_config'->>'priority_policy', 'least_recent_use_wins'),
      'conflict_resolution',   COALESCE(v_meta->'reservations_config'->>'conflict_resolution', 'community_vote'),
      'cancellation_policy',   COALESCE(v_meta->'reservations_config'->>'cancellation_policy', 'open')
    ),
    'invitations_config', jsonb_build_object(
      'who_can_invite',  COALESCE(v_meta->'invitations_config'->>'who_can_invite', 'admins'),
      'open_invites',    COALESCE((v_meta->'invitations_config'->>'open_invites')::boolean, false)
    ),
    'members_config', jsonb_build_object(
      'show_reputation', COALESCE((v_meta->'members_config'->>'show_reputation')::boolean, true)
    ),
    'available_actions', v_actions
  );
END $$;

-- 3. list_context_members_with_reputation — respeta el opt-out del grupo.
create or replace function public.list_context_members_with_reputation(
  p_context_actor_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.actor_memberships
    where context_actor_id = p_context_actor_id
      and member_actor_id = v_caller
      and membership_status = 'active'
  ) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;

  -- R.14.D: el grupo puede apagar la reputación (members_config.show_reputation).
  -- Default true (opt-out). Con reputación apagada devolvemos [] y iOS oculta
  -- leaderboards, badges y la sección de detalle sin lógica extra.
  if not coalesce(
    (select (a.metadata->'members_config'->>'show_reputation')::boolean
       from public.actors a where a.id = p_context_actor_id),
    true
  ) then
    return '[]'::jsonb;
  end if;

  return coalesce((
    with members as (
      select m.member_actor_id as actor_id,
             a.display_name,
             m.membership_type
      from public.actor_memberships m
      join public.actors a on a.id = m.member_actor_id
      where m.context_actor_id = p_context_actor_id
        and m.membership_status = 'active'
    ),
    event_stats as (
      select ep.participant_actor_id as actor_id,
        count(*) filter (where ep.status = 'attended') as attended_events,
        count(*) filter (where ep.status = 'no_show')  as missed_events,
        count(*) filter (where ep.status = 'late')     as late_events,
        count(*) filter (where ep.status = 'cancelled') as cancelled_events
      from public.event_participants ep
      join public.calendar_events ce on ce.id = ep.event_id
      where ce.context_actor_id = p_context_actor_id
      group by ep.participant_actor_id
    ),
    hosted_stats as (
      select ce.host_actor_id as actor_id,
             count(*) as hosted_events
      from public.calendar_events ce
      where ce.context_actor_id = p_context_actor_id
        and ce.host_actor_id is not null
      group by ce.host_actor_id
    ),
    obligation_stats as (
      select o.debtor_actor_id as actor_id,
        count(*) filter (where o.status='open' and o.obligation_type='fine') as open_fines,
        count(*) filter (where o.status='open' and o.obligation_type in ('expense_share','iou','other')) as open_money,
        count(*) filter (where o.status='settled' and o.obligation_type in ('expense_share','iou','other')) as settled_money
      from public.obligations o
      where o.context_actor_id = p_context_actor_id
      group by o.debtor_actor_id
    ),
    activity_stats as (
      select ae.actor_id,
             count(*) as recent_activity_count
      from public.activity_events ae
      where ae.context_actor_id = p_context_actor_id
        and ae.created_at > now() - interval '14 days'
        and ae.actor_id is not null
      group by ae.actor_id
    )
    select jsonb_agg(jsonb_build_object(
      'actor_id',              m.actor_id,
      'display_name',          m.display_name,
      'membership_type',       m.membership_type,
      'attended_events',       coalesce(es.attended_events, 0),
      'missed_events',         coalesce(es.missed_events, 0),
      'late_events',           coalesce(es.late_events, 0),
      'cancelled_events',      coalesce(es.cancelled_events, 0),
      'hosted_events',         coalesce(hs.hosted_events, 0),
      'open_fines',            coalesce(os.open_fines, 0),
      'open_money',            coalesce(os.open_money, 0),
      'settled_money',         coalesce(os.settled_money, 0),
      'recent_activity_count', coalesce(acs.recent_activity_count, 0)
    ))
    from members m
    left join event_stats es      on es.actor_id  = m.actor_id
    left join hosted_stats hs     on hs.actor_id  = m.actor_id
    left join obligation_stats os on os.actor_id  = m.actor_id
    left join activity_stats acs  on acs.actor_id = m.actor_id
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.list_context_members_with_reputation(uuid) from public, anon;
grant execute on function public.list_context_members_with_reputation(uuid) to authenticated, service_role;
