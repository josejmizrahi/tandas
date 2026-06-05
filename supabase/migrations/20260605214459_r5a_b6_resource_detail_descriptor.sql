-- ============================================================================
-- R.5A.B.6 — resource_detail_descriptor(p_resource_id) consolidated RPC
-- ============================================================================
-- Devuelve jsonb consolidando B.0-B.5b:
--   resource + class + subtype + effective_capabilities + rights +
--   sections (filtradas) + widgets (filtradas) + actions + action_forms +
--   state + metrics + relations + linked_documents + activity_preview.
--
-- linked_events / linked_obligations / linked_decisions = [] en B.6 (placeholder
-- hasta que existan FK directos en esas tablas; hoy se infieren via
-- resource_relations que ya viaja en `relations`).
--
-- Visibilidad: caller debe ser owner o is_context_member del owner.
-- ============================================================================

create or replace function public.resource_detail_descriptor(p_resource_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
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
  v_activity_preview jsonb;
begin
  if auth.uid() is null then raise exception 'unauthenticated' using errcode='42501'; end if;
  v_actor := public.current_actor_id();
  if v_actor is null then raise exception 'missing person actor' using errcode='42501'; end if;

  select to_jsonb(r.*), r.canonical_owner_actor_id, r.resource_class_key, r.resource_subtype_key, r.status
    into v_resource, v_owner, v_class_key, v_subtype_key, v_status
    from public.resources r where r.id = p_resource_id;
  if v_owner is null then
    raise exception 'resource not found' using errcode='P0002';
  end if;
  if not (v_actor = v_owner or public.is_context_member(v_owner)) then
    raise exception 'not a member of resource context' using errcode='42501';
  end if;

  -- Fallback a generic si NULL (B.1 backfill ya las puso; defensa extra)
  v_class_key := coalesce(v_class_key, 'generic');
  v_subtype_key := coalesce(v_subtype_key, 'generic_resource');

  select to_jsonb(c.*) into v_class from public.resource_classes c where c.class_key = v_class_key;
  select to_jsonb(s.*) into v_subtype from public.resource_subtypes s where s.subtype_key = v_subtype_key;

  -- effective_capabilities (delegate to B.2 RPC)
  v_caps_descriptor := public.effective_resource_capabilities(p_resource_id);
  select coalesce(array_agg(value::text), array[]::text[]) into v_effective
    from jsonb_array_elements_text(v_caps_descriptor->'effective');

  -- rights (activos: NO revoked / expired)
  select coalesce(jsonb_agg(jsonb_build_object(
           'right_id', rr.id,
           'holder_actor_id', rr.holder_actor_id,
           'holder_display_name', (select display_name from public.actors a where a.id = rr.holder_actor_id),
           'right_kind', rr.right_kind,
           'percent', rr.percent,
           'scope', rr.scope,
           'starts_at', rr.starts_at,
           'ends_at', rr.ends_at
         ) order by rr.right_kind, rr.holder_actor_id), '[]'::jsonb)
    into v_rights
    from public.resource_rights rr
   where rr.resource_id = p_resource_id
     and rr.revoked_at is null
     and rr.expired_at is null;

  -- sections (filtered by required_capability ∈ effective + visible_when_status)
  select coalesce(jsonb_agg(jsonb_build_object(
           'section_key', ss.section_key,
           'display_name', sc.display_name,
           'icon', sc.icon,
           'sort_order', ss.sort_order,
           'visible', true,
           'required_capability', ss.required_capability,
           'required_rights', ss.required_rights,
           'visible_when_status', ss.visible_when_status
         ) order by ss.sort_order, ss.section_key), '[]'::jsonb)
    into v_sections
    from public.resource_subtype_sections ss
    join public.resource_section_catalog sc on sc.section_key = ss.section_key
   where ss.subtype_key = v_subtype_key
     and (ss.required_capability is null or ss.required_capability = any(v_effective))
     and (coalesce(array_length(ss.visible_when_status, 1), 0) = 0
          or v_status = any(ss.visible_when_status));

  -- widgets (filtered by required_capability)
  select coalesce(jsonb_agg(jsonb_build_object(
           'widget_key', sw.widget_key,
           'display_name', wc.display_name,
           'icon', wc.icon,
           'data_source_key', wc.data_source_key,
           'sort_order', sw.sort_order
         ) order by sw.sort_order, sw.widget_key), '[]'::jsonb)
    into v_widgets
    from public.resource_subtype_widgets sw
    join public.resource_dashboard_widgets wc on wc.widget_key = sw.widget_key
   where sw.subtype_key = v_subtype_key
     and (sw.required_capability is null or sw.required_capability = any(v_effective));

  -- actions (delegate to F.2X canonical resource_available_actions + enrich)
  with avail as (
    select * from public.resource_available_actions(p_resource_id, v_actor)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'action_key', a.action_key,
           'label', a.label,
           'section', a.section,
           'enabled', a.enabled,
           'reason', a.reason,
           'required_rights', a.required_rights,
           'required_capabilities', a.required_capabilities,
           'mode', rac.execution_mode,
           'decision_template_key', rac.decision_template_key,
           'form_schema_present', exists(
             select 1 from public.resource_action_forms raf
              where raf.action_key = a.action_key
                and raf.form_schema <> '{}'::jsonb
                and (raf.form_schema->'fields' is null or raf.form_schema->'fields' <> '[]'::jsonb)
           ),
           'dangerous', coalesce(raf2.dangerous, rac.dangerous, false),
           'confirmation_required', coalesce(raf2.confirmation_required, rac.confirmation_required, false)
         ) order by a.section, a.action_key), '[]'::jsonb)
    into v_actions
    from avail a
    left join public.resource_action_catalog rac on rac.action_key = a.action_key
    left join public.resource_action_forms raf2 on raf2.action_key = a.action_key;

  -- action_forms (map keyed by action_key, sólo para acciones disponibles arriba)
  with avail_keys as (
    select distinct a.action_key from public.resource_available_actions(p_resource_id, v_actor) a
  )
  select coalesce(jsonb_object_agg(raf.action_key, jsonb_build_object(
           'form_schema', raf.form_schema,
           'default_payload', raf.default_payload,
           'dangerous', coalesce(raf.dangerous, rac.dangerous, false),
           'confirmation_required', coalesce(raf.confirmation_required, rac.confirmation_required, false)
         )), '{}'::jsonb)
    into v_action_forms
    from public.resource_action_forms raf
    join public.resource_action_catalog rac on rac.action_key = raf.action_key
    join avail_keys ak on ak.action_key = raf.action_key;

  -- state
  v_state := jsonb_build_object(
    'status', v_status,
    'archived', (v_resource->>'archived_at' is not null),
    'archived_at', v_resource->'archived_at',
    'locked_for_governance', false,
    'open_decision_id', null
  );

  -- metrics
  v_metrics := jsonb_build_object(
    'estimated_value', v_resource->'estimated_value',
    'currency', v_resource->'currency',
    'balance', null,
    'last_movement_at', (select max(occurred_at) from public.activity_events where resource_id = p_resource_id)
  );

  -- relations (delegate B.3 RPC)
  v_relations := public.list_resource_relations(p_resource_id);

  -- linked_documents (resource_id directo)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'title', d.title,
           'document_type', d.document_type,
           'created_at', d.created_at
         ) order by d.created_at desc), '[]'::jsonb)
    into v_linked_documents
    from (
      select * from public.documents
       where resource_id = p_resource_id
         and archived_at is null
       order by created_at desc
       limit 5
    ) d;

  -- activity_preview (últimos 10 eventos del resource)
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', ae.id,
           'event_type', ae.event_type,
           'actor_id', ae.actor_id,
           'payload', ae.payload,
           'occurred_at', ae.occurred_at
         ) order by ae.occurred_at desc), '[]'::jsonb)
    into v_activity_preview
    from (
      select * from public.activity_events
       where resource_id = p_resource_id
       order by occurred_at desc
       limit 10
    ) ae;

  return jsonb_build_object(
    'resource', v_resource,
    'class', v_class,
    'subtype', v_subtype,
    'effective_capabilities', to_jsonb(v_effective),
    'rights', v_rights,
    'sections', v_sections,
    'widgets', v_widgets,
    'actions', v_actions,
    'action_forms', v_action_forms,
    'state', v_state,
    'metrics', v_metrics,
    'relations', v_relations,
    'linked_events', '[]'::jsonb,
    'linked_documents', v_linked_documents,
    'linked_obligations', '[]'::jsonb,
    'linked_decisions', '[]'::jsonb,
    'activity_preview', v_activity_preview
  );
end;
$$;

comment on function public.resource_detail_descriptor(uuid) is
  'R.5A.B.6: descriptor consolidado de Resource. Une class/subtype/effective_capabilities/rights/sections/widgets/actions/action_forms/state/metrics/relations/activity. linked_events/obligations/decisions = [] (inferibles via relations).';

revoke all on function public.resource_detail_descriptor(uuid) from public, anon;
grant execute on function public.resource_detail_descriptor(uuid) to authenticated, service_role;
