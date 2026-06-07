-- R.5A.B.6.1 — Enriquece resource_detail_descriptor populando los arrays
-- linked_events/linked_obligations/linked_decisions (antes siempre []).
--
-- Doctrina founder: el descriptor debe surface "qué está conectado a este
-- recurso" para que iOS V2 muestre eventos/obligaciones/decisiones reales
-- sin requerir queries adicionales. Joins vía resource_reservations que
-- es el bridge canónico:
--   linked_events     := events de reservas del recurso (source_event_id)
--   linked_obligations := obligaciones con source_reservation_id en reservas del recurso
--   linked_decisions  := decisiones de reservas del recurso (source_decision_id)
-- + decisiones cuyo payload->resource_id apunta a este recurso (decisiones
--   transversales como transferencias/governance).
--
-- Slice additive: misma signature (uuid → jsonb), shape estable salvo que
-- los tres arrays ahora pueden tener contenido. iOS recibe JSONValue arrays
-- y filtra/renderea. Limite 5 por array, ordenado por relevancia temporal.

CREATE OR REPLACE FUNCTION public.resource_detail_descriptor(p_resource_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
declare
  v_actor uuid;
  v_owner uuid;
  v_resource jsonb;
  v_class jsonb;
  v_subtype jsonb;
  v_effective text[];
  v_caps_descriptor jsonb;
  v_rights jsonb;
  v_sections jsonb;
  v_widgets jsonb;
  v_actions jsonb;
  v_action_forms jsonb;
  v_state jsonb;
  v_metrics jsonb;
  v_relations jsonb;
  v_status text;
  v_class_key text;
  v_subtype_key text;
  v_linked_documents jsonb;
  v_linked_events jsonb;
  v_linked_obligations jsonb;
  v_linked_decisions jsonb;
  v_activity_preview jsonb;
  v_available jsonb;
begin
  if auth.uid() is null then raise exception 'unauthenticated' using errcode='42501'; end if;
  v_actor := public.current_actor_id();
  if v_actor is null then raise exception 'missing person actor' using errcode='42501'; end if;

  select to_jsonb(r.*), r.canonical_owner_actor_id, r.resource_class_key, r.resource_subtype_key, r.status
    into v_resource, v_owner, v_class_key, v_subtype_key, v_status
    from public.resources r where r.id = p_resource_id;
  if v_owner is null then raise exception 'resource not found' using errcode='P0002'; end if;
  if not (v_actor = v_owner or public.is_context_member(v_owner)) then
    raise exception 'not a member of resource context' using errcode='42501';
  end if;

  v_class_key := coalesce(v_class_key, 'generic');
  v_subtype_key := coalesce(v_subtype_key, 'generic_resource');

  select to_jsonb(c.*) into v_class from public.resource_classes c where c.class_key = v_class_key;
  select to_jsonb(s.*) into v_subtype from public.resource_subtypes s where s.subtype_key = v_subtype_key;

  v_caps_descriptor := public.effective_resource_capabilities(p_resource_id);
  select coalesce(array_agg(value::text), array[]::text[]) into v_effective
    from jsonb_array_elements_text(v_caps_descriptor->'effective');

  select coalesce(jsonb_agg(jsonb_build_object(
           'right_id', rr.id, 'holder_actor_id', rr.holder_actor_id,
           'holder_display_name', (select display_name from public.actors a where a.id = rr.holder_actor_id),
           'right_kind', rr.right_kind, 'percent', rr.percent, 'scope', rr.scope,
           'starts_at', rr.starts_at, 'ends_at', rr.ends_at
         ) order by rr.right_kind, rr.holder_actor_id), '[]'::jsonb)
    into v_rights
    from public.resource_rights rr
   where rr.resource_id = p_resource_id and rr.revoked_at is null and rr.expired_at is null;

  select coalesce(jsonb_agg(jsonb_build_object(
           'section_key', ss.section_key, 'display_name', sc.display_name,
           'icon', sc.icon, 'sort_order', ss.sort_order, 'visible', true,
           'required_capability', ss.required_capability,
           'required_rights', ss.required_rights, 'visible_when_status', ss.visible_when_status
         ) order by ss.sort_order, ss.section_key), '[]'::jsonb)
    into v_sections
    from public.resource_subtype_sections ss
    join public.resource_section_catalog sc on sc.section_key = ss.section_key
   where ss.subtype_key = v_subtype_key
     and (ss.required_capability is null or ss.required_capability = any(v_effective))
     and (coalesce(array_length(ss.visible_when_status, 1), 0) = 0
          or v_status = any(ss.visible_when_status));

  select coalesce(jsonb_agg(jsonb_build_object(
           'widget_key', sw.widget_key, 'display_name', wc.display_name,
           'icon', wc.icon, 'data_source_key', wc.data_source_key, 'sort_order', sw.sort_order
         ) order by sw.sort_order, sw.widget_key), '[]'::jsonb)
    into v_widgets
    from public.resource_subtype_widgets sw
    join public.resource_dashboard_widgets wc on wc.widget_key = sw.widget_key
   where sw.subtype_key = v_subtype_key
     and (sw.required_capability is null or sw.required_capability = any(v_effective));

  v_available := public.resource_available_actions(p_resource_id, v_actor);

  select coalesce(jsonb_agg(jsonb_build_object(
           'action_key', a->>'action_key',
           'label', a->>'label',
           'section', a->>'section',
           'enabled', (a->>'enabled')::boolean,
           'reason', a->>'reason',
           'required_rights', a->'required_rights',
           'required_capabilities', a->'required_capabilities',
           'mode', rac.execution_mode,
           'decision_template_key', rac.decision_template_key,
           'form_schema_present', exists(
             select 1 from public.resource_action_forms raf
              where raf.action_key = a->>'action_key'
                and raf.form_schema <> '{}'::jsonb
                and (raf.form_schema->'fields' is null or raf.form_schema->'fields' <> '[]'::jsonb)
           ),
           'dangerous', coalesce(raf2.dangerous, rac.dangerous, false),
           'confirmation_required', coalesce(raf2.confirmation_required, rac.confirmation_required, false)
         ) order by (a->>'section'), (a->>'action_key')), '[]'::jsonb)
    into v_actions
    from jsonb_array_elements(v_available) a
    left join public.resource_action_catalog rac on rac.action_key = a->>'action_key'
    left join public.resource_action_forms raf2 on raf2.action_key = a->>'action_key';

  select coalesce(jsonb_object_agg(raf.action_key, jsonb_build_object(
           'form_schema', raf.form_schema,
           'default_payload', raf.default_payload,
           'dangerous', coalesce(raf.dangerous, rac.dangerous, false),
           'confirmation_required', coalesce(raf.confirmation_required, rac.confirmation_required, false)
         )), '{}'::jsonb)
    into v_action_forms
    from public.resource_action_forms raf
    join public.resource_action_catalog rac on rac.action_key = raf.action_key
    where raf.action_key in (
      select a->>'action_key' from jsonb_array_elements(v_available) a
    );

  v_state := jsonb_build_object(
    'status', v_status,
    'archived', (v_resource->>'archived_at' is not null),
    'archived_at', v_resource->'archived_at',
    'locked_for_governance', false,
    'open_decision_id', null
  );

  v_metrics := jsonb_build_object(
    'estimated_value', v_resource->'estimated_value',
    'currency', v_resource->'currency',
    'balance', null,
    'last_movement_at', (select max(occurred_at) from public.activity_events where resource_id = p_resource_id)
  );

  v_relations := public.list_resource_relations(p_resource_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'title', d.title,
           'document_type', d.document_type, 'created_at', d.created_at
         ) order by d.created_at desc), '[]'::jsonb)
    into v_linked_documents
    from (
      select * from public.documents
       where resource_id = p_resource_id and archived_at is null
       order by created_at desc limit 5
    ) d;

  -- B.6.1 — linked_events via resource_reservations.source_event_id (recursos
  -- agendados generan reservas atadas al evento original).
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', ce.id,
           'title', ce.title,
           'event_type', ce.event_type,
           'starts_at', ce.starts_at,
           'ends_at', ce.ends_at,
           'status', ce.status,
           'host_actor_id', ce.host_actor_id
         ) order by ce.starts_at desc), '[]'::jsonb)
    into v_linked_events
    from (
      select distinct ce.*
        from public.calendar_events ce
        join public.resource_reservations rr on rr.source_event_id = ce.id
       where rr.resource_id = p_resource_id
         and ce.cancelled_at is null
       order by ce.starts_at desc limit 5
    ) ce;

  -- B.6.1 — linked_obligations via obligations.source_reservation_id (cuotas
  -- y deudas derivadas de uso del recurso). Solo abiertas o recientes.
  select coalesce(jsonb_agg(jsonb_build_object(
           'obligation_id', o.id,
           'title', o.title,
           'obligation_type', o.obligation_type,
           'obligation_kind', o.obligation_kind,
           'amount', o.amount,
           'currency', o.currency,
           'status', o.status,
           'due_at', o.due_at,
           'debtor_actor_id', o.debtor_actor_id,
           'creditor_actor_id', o.creditor_actor_id
         ) order by o.due_at desc nulls last, o.created_at desc), '[]'::jsonb)
    into v_linked_obligations
    from (
      select distinct o.*
        from public.obligations o
       where o.source_reservation_id in (
         select id from public.resource_reservations where resource_id = p_resource_id
       )
       order by o.due_at desc nulls last, o.created_at desc limit 5
    ) o;

  -- B.6.1 — linked_decisions via reservas del recurso + decisiones cuyo
  -- payload->resource_id apunta a este recurso (transfers/governance).
  select coalesce(jsonb_agg(jsonb_build_object(
           'decision_id', d.id,
           'title', d.title,
           'decision_type', d.decision_type,
           'template_key', d.template_key,
           'status', d.status,
           'opens_at', d.opens_at,
           'closes_at', d.closes_at,
           'decided_at', d.decided_at
         ) order by d.created_at desc), '[]'::jsonb)
    into v_linked_decisions
    from (
      select distinct d.*
        from public.decisions d
       where exists (
         select 1 from public.resource_reservations rr
          where rr.resource_id = p_resource_id
            and rr.source_decision_id = d.id
       )
       or (d.payload ? 'resource_id' and (d.payload->>'resource_id')::uuid = p_resource_id)
       order by d.created_at desc limit 5
    ) d;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', ae.id, 'event_type', ae.event_type, 'actor_id', ae.actor_id,
           'payload', ae.payload, 'occurred_at', ae.occurred_at
         ) order by ae.occurred_at desc), '[]'::jsonb)
    into v_activity_preview
    from (
      select * from public.activity_events
       where resource_id = p_resource_id
       order by occurred_at desc limit 10
    ) ae;

  return jsonb_build_object(
    'resource', v_resource, 'class', v_class, 'subtype', v_subtype,
    'effective_capabilities', to_jsonb(v_effective),
    'rights', v_rights, 'sections', v_sections, 'widgets', v_widgets,
    'actions', v_actions, 'action_forms', v_action_forms,
    'state', v_state, 'metrics', v_metrics, 'relations', v_relations,
    'linked_events', v_linked_events,
    'linked_documents', v_linked_documents,
    'linked_obligations', v_linked_obligations,
    'linked_decisions', v_linked_decisions,
    'activity_preview', v_activity_preview
  );
end;
$function$;
