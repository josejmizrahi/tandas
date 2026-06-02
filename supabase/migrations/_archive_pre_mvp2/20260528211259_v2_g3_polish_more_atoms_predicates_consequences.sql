-- V2-G3 polish — extender la superficie del engine para cubrir 80% del
-- universo de eventos observado en producción + abrir el puente engine→votos.
--
-- DATA (idempotente):
--   +5 triggers (money.settlement_recorded, contribution.logged,
--                sanction.issued, dispute.opened, mandate.granted)
--   +3 conditions (amount_between, target_role_in, is_first_offense)
--   +2 consequences (create_pool_charge, start_vote)
--
-- + UPDATE de compatible_conditions / compatible_consequences en los
--   3 triggers existentes para que el iOS picker exponga las nuevas
--   piezas donde tienen sentido.
--
-- CODE: _rule_eval_predicate y _rule_eval_dispatch ganan ramas para
-- los nuevos kinds. Aún hardcoded ELSIF — el refactor a handler
-- registry queda para V3. Para 15 atoms vivos es manejable.
--
-- consequence.start_vote es el puente engine→vota: cuando se cumple
-- un predicate, en vez de aplicar consecuencia directamente, se
-- arranca una decisión humana. Cierra la doctrina "todo lo que
-- cambia autoridad va a voto, todo lo que aplica autoridad existente
-- es engine" — usa esta consequence para escalar de routine a
-- decisión cuando la regla detecta que el caso requiere deliberación.

-- ============================================================
-- 1) Atom catalog seed (data-only).
-- ============================================================

INSERT INTO public.rule_shapes_catalog
  (shape_key, category, display_name, description, schema, resource_types, metadata)
VALUES
  -- +5 triggers
  ('trigger.money.settlement_recorded', 'trigger',
   'Cuando alguien registra un pago',
   'Se dispara cuando se registra un pago entre miembros o al pool.',
   jsonb_build_object(
     'event_type', 'money.settlement_recorded',
     'payload_keys', jsonb_build_array('amount','unit','paid_by_membership_id','paid_to_kind'),
     'compatible_conditions', jsonb_build_array(
       'condition.actor_role_in','condition.amount_above','condition.amount_between'),
     'compatible_consequences', jsonb_build_array(
       'consequence.send_notification','consequence.create_pool_charge'),
     'scope', 'group'
   ),
   ARRAY[]::text[],
   jsonb_build_object('icon','arrow.left.arrow.right')),

  ('trigger.contribution.logged', 'trigger',
   'Cuando alguien registra una contribución',
   'Se dispara cuando un miembro reclama haber contribuido algo al grupo.',
   jsonb_build_object(
     'event_type', 'contribution.logged',
     'payload_keys', jsonb_build_array('contribution_kind','resource_id','membership_id'),
     'compatible_conditions', jsonb_build_array('condition.actor_role_in'),
     'compatible_consequences', jsonb_build_array(
       'consequence.send_notification','consequence.start_vote'),
     'scope', 'member'
   ),
   ARRAY[]::text[],
   jsonb_build_object('icon','hands.sparkles')),

  ('trigger.sanction.issued', 'trigger',
   'Cuando se emite una sanción',
   'Se dispara cuando se sanciona a un miembro (manual o por otra regla).',
   jsonb_build_object(
     'event_type', 'sanction.issued',
     'payload_keys', jsonb_build_array('kind','target'),
     'compatible_conditions', jsonb_build_array(
       'condition.actor_role_in','condition.target_role_in','condition.is_first_offense'),
     'compatible_consequences', jsonb_build_array(
       'consequence.send_notification','consequence.start_vote'),
     'scope', 'member'
   ),
   ARRAY[]::text[],
   jsonb_build_object('icon','exclamationmark.shield')),

  ('trigger.dispute.opened', 'trigger',
   'Cuando se abre una disputa',
   'Se dispara cuando alguien abre una disputa contra una sanción, regla, recurso, etc.',
   jsonb_build_object(
     'event_type', 'dispute.opened',
     'payload_keys', jsonb_build_array('subject_kind','subject_id'),
     'compatible_conditions', jsonb_build_array('condition.actor_role_in'),
     'compatible_consequences', jsonb_build_array(
       'consequence.send_notification','consequence.start_vote'),
     'scope', 'group'
   ),
   ARRAY[]::text[],
   jsonb_build_object('icon','flag.checkered')),

  ('trigger.mandate.granted', 'trigger',
   'Cuando se otorga un mandato',
   'Se dispara cuando alguien recibe autorización para actuar en nombre de otro.',
   jsonb_build_object(
     'event_type', 'mandate.granted',
     'payload_keys', jsonb_build_array('representative_membership_id','grantor_membership_id','scope'),
     'compatible_conditions', jsonb_build_array('condition.actor_role_in'),
     'compatible_consequences', jsonb_build_array('consequence.send_notification'),
     'scope', 'member'
   ),
   ARRAY[]::text[],
   jsonb_build_object('icon','person.crop.rectangle.badge.checkmark')),

  -- +3 conditions
  ('condition.amount_between', 'condition',
   'El monto está entre dos umbrales',
   'Solo dispara cuando el monto del evento cae entre amount_min y amount_max (inclusive).',
   jsonb_build_object(
     'kind', 'amount_between',
     'fields', jsonb_build_array(
       jsonb_build_object('key','amount_min','type','number','required',true,'min',0,'label','Mínimo'),
       jsonb_build_object('key','amount_max','type','number','required',true,'min',0,'label','Máximo'),
       jsonb_build_object('key','currency','type','string','required',true,'default','MXN','label','Moneda')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  ('condition.target_role_in', 'condition',
   'El afectado tiene cierto rol',
   'Solo dispara cuando la persona afectada por el evento tiene uno de los roles indicados.',
   jsonb_build_object(
     'kind', 'target_role_in',
     'fields', jsonb_build_array(
       jsonb_build_object('key','roles','type','string_array','required',true,'label','Roles del afectado')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  ('condition.is_first_offense', 'condition',
   'Es la primera ofensa',
   'Solo dispara cuando el actor no tiene sanciones contra él en los últimos N días.',
   jsonb_build_object(
     'kind', 'is_first_offense',
     'fields', jsonb_build_array(
       jsonb_build_object('key','lookback_days','type','integer','required',true,
                         'default',30,'min',1,'label','Días hacia atrás')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  -- +2 consequences
  ('consequence.create_pool_charge', 'consequence',
   'Crear cobro al pool',
   'Crea una obligación de tipo cuota / buy_in / fee contra el miembro afectado.',
   jsonb_build_object(
     'action', 'create_pool_charge',
     'execution', 'sync',
     'authority_required', 'pool_charge.record',
     'fields', jsonb_build_array(
       jsonb_build_object('key','amount','type','number','required',true,'min',0,'label','Monto'),
       jsonb_build_object('key','currency','type','string','required',true,'default','MXN','label','Moneda'),
       jsonb_build_object('key','charge_kind','type','enum','required',true,
                         'enum', jsonb_build_array('quota','buy_in','fee'),
                         'label','Tipo de cobro'),
       jsonb_build_object('key','reason','type','string','required',false,'label','Razón')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb),

  ('consequence.start_vote', 'consequence',
   'Escalar a votación',
   'Arranca una decisión del grupo. Sirve como puente engine→votos: cuando la regla detecta un caso que requiere deliberación humana, en vez de aplicar consecuencia automática, llama al grupo a votar.',
   jsonb_build_object(
     'action', 'start_vote',
     'execution', 'sync',
     'authority_required', 'decisions.create',
     'fields', jsonb_build_array(
       jsonb_build_object('key','title','type','string','required',true,'label','Título de la decisión'),
       jsonb_build_object('key','decision_type','type','enum','required',true,
                         'enum', jsonb_build_array('proposal','poll','membership','sanction_appeal',
                                                   'rule_change','mandate_revoke','dissolution'),
                         'default','proposal','label','Tipo de decisión'),
       jsonb_build_object('key','method','type','enum','required',true,
                         'enum', jsonb_build_array('majority','supermajority','consensus','consent'),
                         'default','majority','label','Método'),
       jsonb_build_object('key','closes_in_hours','type','integer','required',true,
                         'default',72,'min',1,'max',720,'label','Horas hasta cerrar'),
       jsonb_build_object('key','use_event_entity','type','boolean','required',true,
                         'default',true,'label','Vincular al objeto del evento')
     )
   ),
   ARRAY[]::text[],
   '{}'::jsonb)
ON CONFLICT (shape_key) DO UPDATE
  SET category       = EXCLUDED.category,
      display_name   = EXCLUDED.display_name,
      description    = EXCLUDED.description,
      schema         = EXCLUDED.schema,
      resource_types = EXCLUDED.resource_types,
      metadata       = EXCLUDED.metadata;

-- ============================================================
-- 2) Update compatibility arrays en triggers existentes.
-- ============================================================

UPDATE public.rule_shapes_catalog SET schema = schema
  || jsonb_build_object(
       'compatible_conditions',
       jsonb_build_array('condition.actor_role_in','condition.amount_above',
                         'condition.amount_between'),
       'compatible_consequences',
       jsonb_build_array('consequence.issue_sanction','consequence.send_notification',
                         'consequence.create_pool_charge','consequence.start_vote')
     )
WHERE shape_key = 'trigger.money.expense_recorded';

UPDATE public.rule_shapes_catalog SET schema = schema
  || jsonb_build_object(
       'compatible_conditions',
       jsonb_build_array('condition.actor_role_in','condition.target_self',
                         'condition.target_role_in'),
       'compatible_consequences',
       jsonb_build_array('consequence.send_notification','consequence.set_membership_state',
                         'consequence.start_vote')
     )
WHERE shape_key = 'trigger.member.state_changed';

UPDATE public.rule_shapes_catalog SET schema = schema
  || jsonb_build_object(
       'compatible_conditions',
       jsonb_build_array('condition.actor_role_in'),
       'compatible_consequences',
       jsonb_build_array('consequence.send_notification','consequence.start_vote')
     )
WHERE shape_key = 'trigger.decision.finalized';

-- ============================================================
-- 3) Extender _rule_eval_predicate con los 3 nuevos kinds.
-- ============================================================

CREATE OR REPLACE FUNCTION public._rule_eval_predicate(
  p_condition_tree jsonb,
  p_event public.group_events
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_kind text;
  v_fields jsonb;
  v_actor_membership uuid;
  v_target_user_id uuid;
  v_target_membership uuid;
  v_actor_roles text[];
  v_target_roles text[];
  v_required_roles jsonb;
  v_role text;
  v_match boolean := false;
  v_event_amount numeric;
  v_threshold numeric;
  v_amount_min numeric;
  v_amount_max numeric;
  v_target uuid;
  v_only_self boolean;
  v_lookback int;
  v_prior_count int;
BEGIN
  IF p_condition_tree IS NULL OR p_condition_tree = '{}'::jsonb OR p_condition_tree = 'null'::jsonb THEN
    RETURN jsonb_build_object('passed', true, 'reason', 'no_predicate');
  END IF;
  v_kind := p_condition_tree->>'kind';
  v_fields := COALESCE(p_condition_tree->'fields', '{}'::jsonb);

  IF v_kind = 'condition.actor_role_in' THEN
    v_required_roles := v_fields->'roles';
    IF v_required_roles IS NULL OR jsonb_typeof(v_required_roles) <> 'array' THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'missing_roles', 'kind', v_kind);
    END IF;
    SELECT id INTO v_actor_membership FROM public.group_memberships
     WHERE group_id = p_event.group_id AND user_id = p_event.actor_user_id;
    IF v_actor_membership IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'actor_not_member', 'kind', v_kind);
    END IF;
    SELECT COALESCE(array_agg(r.key), ARRAY[]::text[]) INTO v_actor_roles
      FROM public.group_member_roles mr
      JOIN public.group_roles r ON r.id = mr.role_id
     WHERE mr.membership_id = v_actor_membership;
    FOR v_role IN SELECT jsonb_array_elements_text(v_required_roles) LOOP
      IF v_role = ANY(v_actor_roles) THEN v_match := true; EXIT; END IF;
    END LOOP;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'role_match' ELSE 'no_role_match' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('actor_roles', to_jsonb(v_actor_roles)));

  ELSIF v_kind = 'condition.target_role_in' THEN
    v_required_roles := v_fields->'roles';
    IF v_required_roles IS NULL OR jsonb_typeof(v_required_roles) <> 'array' THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'missing_roles', 'kind', v_kind);
    END IF;
    v_target_user_id := NULLIF(p_event.payload->>'target_user_id','')::uuid;
    IF v_target_user_id IS NULL THEN
      v_target_user_id := NULLIF(p_event.payload->>'target','')::uuid;
    END IF;
    IF v_target_user_id IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'no_target_in_payload', 'kind', v_kind);
    END IF;
    SELECT id INTO v_target_membership FROM public.group_memberships
     WHERE group_id = p_event.group_id AND user_id = v_target_user_id;
    IF v_target_membership IS NULL THEN
      -- target may be a membership_id directly (e.g. sanction.issued.target)
      SELECT id INTO v_target_membership FROM public.group_memberships
       WHERE group_id = p_event.group_id AND id = v_target_user_id;
    END IF;
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('passed', false, 'reason', 'target_not_member', 'kind', v_kind);
    END IF;
    SELECT COALESCE(array_agg(r.key), ARRAY[]::text[]) INTO v_target_roles
      FROM public.group_member_roles mr
      JOIN public.group_roles r ON r.id = mr.role_id
     WHERE mr.membership_id = v_target_membership;
    FOR v_role IN SELECT jsonb_array_elements_text(v_required_roles) LOOP
      IF v_role = ANY(v_target_roles) THEN v_match := true; EXIT; END IF;
    END LOOP;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'target_role_match' ELSE 'no_target_role_match' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('target_roles', to_jsonb(v_target_roles)));

  ELSIF v_kind = 'condition.amount_above' THEN
    v_threshold := COALESCE((v_fields->>'amount')::numeric, 0);
    v_event_amount := COALESCE((p_event.payload->>'amount')::numeric, 0);
    v_match := v_event_amount > v_threshold;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'above_threshold' ELSE 'below_threshold' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('event_amount', v_event_amount, 'threshold', v_threshold));

  ELSIF v_kind = 'condition.amount_between' THEN
    v_amount_min := COALESCE((v_fields->>'amount_min')::numeric, 0);
    v_amount_max := COALESCE((v_fields->>'amount_max')::numeric, 0);
    v_event_amount := COALESCE((p_event.payload->>'amount')::numeric, 0);
    v_match := v_event_amount >= v_amount_min AND v_event_amount <= v_amount_max;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'within_range' ELSE 'out_of_range' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object(
        'event_amount', v_event_amount,
        'amount_min', v_amount_min,
        'amount_max', v_amount_max));

  ELSIF v_kind = 'condition.target_self' THEN
    v_only_self := COALESCE((v_fields->>'only_self')::boolean, true);
    v_target := NULLIF(p_event.payload->>'target_user_id','')::uuid;
    IF NOT v_only_self THEN
      RETURN jsonb_build_object('passed', true, 'reason', 'self_check_disabled', 'kind', v_kind);
    END IF;
    v_match := (v_target IS NOT DISTINCT FROM p_event.actor_user_id);
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'actor_is_target' ELSE 'actor_not_target' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object('actor', p_event.actor_user_id, 'target', v_target));

  ELSIF v_kind = 'condition.is_first_offense' THEN
    v_lookback := COALESCE((v_fields->>'lookback_days')::int, 30);
    -- Count prior sanctions against the actor (target_membership_id) in window.
    SELECT count(*) INTO v_prior_count
      FROM public.group_sanctions s
      JOIN public.group_memberships m ON m.id = s.target_membership_id
     WHERE m.user_id = p_event.actor_user_id
       AND s.group_id = p_event.group_id
       AND s.created_at > now() - (v_lookback || ' days')::interval;
    v_match := v_prior_count = 0;
    RETURN jsonb_build_object('passed', v_match,
      'reason', CASE WHEN v_match THEN 'no_prior_sanctions' ELSE 'has_prior_sanctions' END,
      'kind', v_kind,
      'evaluated_value', jsonb_build_object(
        'prior_count', v_prior_count,
        'lookback_days', v_lookback));

  ELSE
    RETURN jsonb_build_object('passed', false, 'reason', 'unknown_predicate_kind',
                              'kind', COALESCE(v_kind,'<null>'));
  END IF;
END;
$$;

-- ============================================================
-- 4) Extender _rule_eval_dispatch con los 2 nuevos kinds.
-- ============================================================

CREATE OR REPLACE FUNCTION public._rule_eval_dispatch(
  p_action jsonb,
  p_event public.group_events,
  p_rule_version_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_kind text := p_action->>'kind';
  v_fields jsonb := COALESCE(p_action->'fields', '{}'::jsonb);
  v_target_user_id uuid;
  v_target_membership uuid;
  v_severity int;
  v_message text;
  v_audience text;
  v_new_state text;
  v_reason text;
  v_sanction_id uuid;
  v_error text;
  v_notified int;
  v_amount numeric;
  v_currency text;
  v_charge_kind text;
  v_obligation_id uuid;
  v_decision_id uuid;
  v_title text;
  v_decision_type text;
  v_method text;
  v_closes_at timestamptz;
  v_use_entity boolean;
  v_ref_kind text;
  v_ref_id uuid;
BEGIN
  v_target_user_id := COALESCE(
    NULLIF(p_event.payload->>'target_user_id','')::uuid,
    p_event.actor_user_id);
  SELECT id INTO v_target_membership FROM public.group_memberships
   WHERE group_id = p_event.group_id AND user_id = v_target_user_id;

  IF v_kind = 'consequence.issue_sanction' THEN
    v_severity := COALESCE((v_fields->>'severity')::int, 1);
    v_reason := COALESCE(v_fields->>'reason', 'Regla con engine');
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found');
    END IF;
    BEGIN
      v_sanction_id := public.issue_sanction(
        p_group_id => p_event.group_id, p_target_membership_id => v_target_membership,
        p_sanction_kind => 'warning', p_reason => v_reason,
        p_amount => NULL, p_unit => NULL, p_ends_at => NULL,
        p_rule_version_id => p_rule_version_id, p_source_event_id => p_event.uuid_id,
        p_client_id => NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_sanction_id,
                                'severity', v_severity);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.set_membership_state' THEN
    v_new_state := v_fields->>'new_state';
    v_reason := v_fields->>'reason';
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found');
    END IF;
    BEGIN
      PERFORM public.set_membership_state(v_target_membership, v_new_state, v_reason, NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_target_membership,
                                'new_state', v_new_state);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.send_notification' THEN
    v_message := COALESCE(v_fields->>'message', 'Regla disparada');
    v_audience := COALESCE(v_fields->>'audience', 'admins');
    v_notified := 0;
    BEGIN
      IF v_audience = 'actor' AND p_event.actor_user_id IS NOT NULL THEN
        INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
        VALUES (p_event.group_id, p_event.actor_user_id, 'rule_consequence',
                jsonb_build_object('rule_version_id', p_rule_version_id,
                                   'message', v_message,
                                   'source_event_id', p_event.uuid_id));
        v_notified := 1;
      ELSIF v_audience = 'group' THEN
        WITH ins AS (
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          SELECT p_event.group_id, gm.user_id, 'rule_consequence',
                 jsonb_build_object('rule_version_id', p_rule_version_id,
                                    'message', v_message,
                                    'source_event_id', p_event.uuid_id)
            FROM public.group_memberships gm
           WHERE gm.group_id = p_event.group_id AND gm.status = 'active'
          RETURNING 1)
        SELECT count(*) INTO v_notified FROM ins;
      ELSE
        WITH ins AS (
          INSERT INTO public.notifications_outbox (group_id, recipient_user_id, category, payload)
          SELECT DISTINCT p_event.group_id, gm.user_id, 'rule_consequence',
                 jsonb_build_object('rule_version_id', p_rule_version_id,
                                    'message', v_message,
                                    'source_event_id', p_event.uuid_id)
            FROM public.group_memberships gm
            JOIN public.group_member_roles mr ON mr.membership_id = gm.id
            JOIN public.group_roles r ON r.id = mr.role_id
           WHERE gm.group_id = p_event.group_id AND gm.status = 'active'
             AND r.key IN ('admin','founder')
          RETURNING 1)
        SELECT count(*) INTO v_notified FROM ins;
      END IF;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'async',
                                'status', 'emitted', 'audience', v_audience,
                                'recipients', v_notified);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'async',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.create_pool_charge' THEN
    v_amount := NULLIF(v_fields->>'amount','')::numeric;
    v_currency := COALESCE(v_fields->>'currency', 'MXN');
    v_charge_kind := v_fields->>'charge_kind';
    v_reason := v_fields->>'reason';
    IF v_target_membership IS NULL THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'target_membership_not_found');
    END IF;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'amount_required');
    END IF;
    IF v_charge_kind NOT IN ('quota','buy_in','fee') THEN
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', 'invalid_charge_kind');
    END IF;
    BEGIN
      v_obligation_id := public.record_pool_charge(
        p_group_id => p_event.group_id,
        p_target_membership_id => v_target_membership,
        p_amount => v_amount,
        p_unit => v_currency,
        p_charge_kind => v_charge_kind,
        p_reason => COALESCE(v_reason, 'Generado por regla con engine'),
        p_mandate_id => NULL,
        p_client_id => NULL);
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_obligation_id,
                                'amount', v_amount, 'currency', v_currency,
                                'charge_kind', v_charge_kind);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSIF v_kind = 'consequence.start_vote' THEN
    v_title := COALESCE(v_fields->>'title', 'Decisión generada por regla');
    v_decision_type := COALESCE(v_fields->>'decision_type', 'proposal');
    v_method := COALESCE(v_fields->>'method', 'majority');
    v_closes_at := now() + (COALESCE((v_fields->>'closes_in_hours')::int, 72)::text || ' hours')::interval;
    v_use_entity := COALESCE((v_fields->>'use_event_entity')::boolean, true);
    v_ref_kind := NULL;
    v_ref_id := NULL;
    IF v_use_entity AND p_event.entity_kind IS NOT NULL AND p_event.entity_id IS NOT NULL THEN
      v_ref_kind := p_event.entity_kind;
      v_ref_id := p_event.entity_id;
    END IF;
    BEGIN
      v_decision_id := public.start_vote(
        p_group_id => p_event.group_id,
        p_title => v_title,
        p_body => format('Disparada por regla %s sobre evento %s', p_rule_version_id::text, p_event.event_type),
        p_decision_type => v_decision_type,
        p_method => v_method,
        p_legitimacy_source => NULL,
        p_opens_at => now(),
        p_closes_at => v_closes_at,
        p_threshold_pct => NULL,
        p_quorum_pct => NULL,
        p_committee_only => false,
        p_reference_kind => v_ref_kind,
        p_reference_id => v_ref_id,
        p_options => NULL,
        p_metadata => jsonb_build_object(
          'engine_rule_version_id', p_rule_version_id,
          'engine_source_event_id', p_event.uuid_id));
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'emitted', 'target_id', v_decision_id,
                                'decision_type', v_decision_type, 'method', v_method,
                                'reference_kind', v_ref_kind);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      RETURN jsonb_build_object('kind', v_kind, 'execution', 'sync',
                                'status', 'failed', 'error', v_error);
    END;

  ELSE
    RETURN jsonb_build_object('kind', COALESCE(v_kind,'<null>'),
                              'execution', 'unknown',
                              'status', 'skipped', 'error', 'unknown_consequence_kind');
  END IF;
END;
$$;
