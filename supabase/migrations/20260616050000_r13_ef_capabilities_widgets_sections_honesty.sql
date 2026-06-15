-- R.13.E + R.13.F — Honesty Sweep backend: capabilities sin uso + widgets/sections sin renderer
--
-- Founder lock 2026-06-16: "nada que no tenga que estar — tanto en el
-- frontend como en el backend". Continuación de R.13.D (action_keys).
--
-- E. capabilities NO_EFFECT (4 zero-reference): DROP del catalog.
--    `depreciable`/`rentable`/`sellable`/`usable` — sin referencias en
--    resource_subtype_capabilities ni resource_type_capabilities ni
--    overrides ni required_capability de sections/widgets/actions.
--
-- F.1 widgets sin renderer iOS (8 de 18): ADD `is_implemented` flag +
--    filter en resource_detail_descriptor. iOS solo routea 10:
--    balance_summary, member_balance_summary, income_summary, lease_status,
--    open_obligations → money; next_event → events; recent_activity →
--    activity; reservation_status, upcoming_reservations → reservations;
--    settlement_status → settlement.
--    Los 8 sin destino (condition/conflicts/custody/document/insurance/
--    maintenance/resource_value/tax) caen al fallback iOS sin headline
--    ni navegación — card inerte. Pattern misma que R.13.D: conservar
--    row del catalog (modelado conceptual) + flip flag cuando ship.
--
-- F.2 sections sin renderer iOS (42 de 47): ADD `is_implemented` flag +
--    filter en resource_detail_descriptor. iOS solo routea 5:
--    reservations, availability, calendar, activity, settings.
--    Las 42 restantes ya estaban filtradas defensivamente en
--    ResourceDetailV2SectionsSection.destinationKey() (línea 38) — backend
--    ahora filtra arriba para coherencia doble-gating.

-- ─────────────────────────────────────────────────────────────────────────
-- R.13.E — DROP capabilities NO_EFFECT
-- ─────────────────────────────────────────────────────────────────────────

delete from public.resource_capabilities_catalog
 where capability_key in ('depreciable', 'rentable', 'sellable', 'usable');

-- ─────────────────────────────────────────────────────────────────────────
-- R.13.F.1 — widgets: is_implemented flag + backfill
-- ─────────────────────────────────────────────────────────────────────────

alter table public.resource_dashboard_widgets
  add column if not exists is_implemented boolean not null default false;

comment on column public.resource_dashboard_widgets.is_implemented is
  'R.13.F 2026-06-16: TRUE si iOS routea el widget a un destination. resource_detail_descriptor filtra widgets no implementados para nunca surface al UI un dashboard tile inerte.';

update public.resource_dashboard_widgets
   set is_implemented = true
 where widget_key in (
   'balance_summary',
   'member_balance_summary',
   'income_summary',
   'lease_status',
   'open_obligations',
   'next_event',
   'recent_activity',
   'reservation_status',
   'upcoming_reservations',
   'settlement_status'
 );

-- ─────────────────────────────────────────────────────────────────────────
-- R.13.F.2 — sections: is_implemented flag + backfill
-- ─────────────────────────────────────────────────────────────────────────

alter table public.resource_section_catalog
  add column if not exists is_implemented boolean not null default false;

comment on column public.resource_section_catalog.is_implemented is
  'R.13.F 2026-06-16: TRUE si iOS routea la section a un destination. resource_detail_descriptor filtra sections no implementadas. iOS ya filtraba defensivamente en ResourceDetailV2SectionsSection — doble gating coherente con doctrina founder.';

update public.resource_section_catalog
   set is_implemented = true
 where section_key in (
   'reservations',
   'availability',
   'calendar',
   'activity',
   'settings'
 );

-- ─────────────────────────────────────────────────────────────────────────
-- R.13.F — resource_detail_descriptor: filter is_implemented
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.resource_detail_descriptor(p_resource_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'auth'
as $function$
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
  v_conflicts jsonb;
  v_open_count integer;
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

  v_class_key   := coalesce(v_class_key, 'generic');
  v_subtype_key := coalesce(v_subtype_key, 'generic_resource');

  select to_jsonb(c.*) into v_class   from public.resource_classes  c where c.class_key   = v_class_key;
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

  -- R.13.F.2 — sections filtradas por is_implemented (iOS solo routea 5)
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
     and sc.is_implemented = true
     and (ss.required_capability is null or ss.required_capability = any(v_effective))
     and (coalesce(array_length(ss.visible_when_status, 1), 0) = 0
          or v_status = any(ss.visible_when_status));

  -- R.13.F.1 — widgets filtrados por is_implemented (iOS solo routea 10)
  select coalesce(jsonb_agg(jsonb_build_object(
           'widget_key', sw.widget_key, 'display_name', wc.display_name,
           'icon', wc.icon, 'data_source_key', wc.data_source_key, 'sort_order', sw.sort_order
         ) order by sw.sort_order, sw.widget_key), '[]'::jsonb)
    into v_widgets
    from public.resource_subtype_widgets sw
    join public.resource_dashboard_widgets wc on wc.widget_key = sw.widget_key
   where sw.subtype_key = v_subtype_key
     and wc.is_implemented = true
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
    left join public.resource_action_forms raf2 on raf2.action_key = a->>'action_key'
   where coalesce(rac.is_implemented, false) = true;

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
    )
      and rac.is_implemented = true;

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
    from (select * from public.documents where resource_id = p_resource_id and archived_at is null
          order by created_at desc limit 5) d;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', ce.id, 'title', ce.title, 'event_type', ce.event_type,
           'starts_at', ce.starts_at, 'ends_at', ce.ends_at, 'status', ce.status,
           'host_actor_id', ce.host_actor_id
         ) order by ce.starts_at desc), '[]'::jsonb)
    into v_linked_events
    from (
      select distinct ce.*
        from public.calendar_events ce
        join public.resource_reservations rr on rr.source_event_id = ce.id
       where rr.resource_id = p_resource_id and ce.cancelled_at is null
       order by ce.starts_at desc limit 5
    ) ce;

  select coalesce(jsonb_agg(jsonb_build_object(
           'obligation_id', o.id, 'title', o.title,
           'obligation_type', o.obligation_type, 'obligation_kind', o.obligation_kind,
           'amount', o.amount, 'currency', o.currency, 'status', o.status,
           'due_at', o.due_at, 'debtor_actor_id', o.debtor_actor_id,
           'creditor_actor_id', o.creditor_actor_id
         ) order by o.due_at desc nulls last, o.created_at desc), '[]'::jsonb)
    into v_linked_obligations
    from (
      select distinct o.* from public.obligations o
       where o.source_reservation_id in (
         select id from public.resource_reservations where resource_id = p_resource_id
       )
       order by o.due_at desc nulls last, o.created_at desc limit 5
    ) o;

  select coalesce(jsonb_agg(jsonb_build_object(
           'decision_id', d.id, 'title', d.title,
           'decision_type', d.decision_type, 'template_key', d.template_key,
           'status', d.status, 'opens_at', d.opens_at, 'closes_at', d.closes_at,
           'decided_at', d.decided_at
         ) order by d.created_at desc), '[]'::jsonb)
    into v_linked_decisions
    from (
      select distinct d.* from public.decisions d
       where exists (select 1 from public.resource_reservations rr
                     where rr.resource_id = p_resource_id and rr.source_decision_id = d.id)
          or (d.payload ? 'resource_id' and (d.payload->>'resource_id')::uuid = p_resource_id)
       order by d.created_at desc limit 5
    ) d;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', ae.id, 'event_type', ae.event_type, 'actor_id', ae.actor_id,
           'payload', ae.payload, 'occurred_at', ae.occurred_at
         ) order by ae.occurred_at desc), '[]'::jsonb)
    into v_activity_preview
    from (select * from public.activity_events where resource_id = p_resource_id
          order by occurred_at desc limit 10) ae;

  begin
    v_conflicts := public.list_resource_conflicts(p_resource_id, false);
  exception when others then
    v_conflicts := jsonb_build_object('resource_id', p_resource_id, 'open_count', 0,
                                      'total_count', 0, 'items', '[]'::jsonb);
  end;
  v_open_count := coalesce((v_conflicts->>'open_count')::int, 0);
  v_sections := public._r5b_strip_conflicts_section_if_clean(v_sections, v_open_count);
  v_widgets  := public._r5b_strip_conflicts_widget_if_clean(v_widgets, v_open_count);

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
    'activity_preview', v_activity_preview,
    'conflicts', v_conflicts
  );
end;
$function$;

revoke execute on function public.resource_detail_descriptor(uuid) from public, anon;
grant execute on function public.resource_detail_descriptor(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- Smoke
-- ─────────────────────────────────────────────────────────────────────────

do $smoke$
declare
  v_caps_total integer;
  v_caps_dropped integer;
  v_widgets_impl integer;
  v_widgets_total integer;
  v_sections_impl integer;
  v_sections_total integer;
begin
  -- E
  select count(*) into v_caps_total from public.resource_capabilities_catalog;
  v_caps_dropped := 42 - v_caps_total;  -- antes 42 (4 NO_EFFECT)
  if v_caps_dropped <> 4 then
    raise exception 'R.13.E smoke fail: esperaba 4 caps dropped, dropped=%, total=%', v_caps_dropped, v_caps_total;
  end if;

  -- F.1 widgets
  select count(*) into v_widgets_total from public.resource_dashboard_widgets;
  select count(*) into v_widgets_impl from public.resource_dashboard_widgets where is_implemented;
  if v_widgets_impl <> 10 then
    raise exception 'R.13.F.1 smoke fail: esperaba 10 widgets implementados, got % de % total', v_widgets_impl, v_widgets_total;
  end if;

  -- F.2 sections
  select count(*) into v_sections_total from public.resource_section_catalog;
  select count(*) into v_sections_impl from public.resource_section_catalog where is_implemented;
  if v_sections_impl <> 5 then
    raise exception 'R.13.F.2 smoke fail: esperaba 5 sections implementadas, got % de % total', v_sections_impl, v_sections_total;
  end if;

  raise notice 'R.13.E+F smoke OK: caps total=% (4 dropped) | widgets impl=%/% | sections impl=%/%',
    v_caps_total, v_widgets_impl, v_widgets_total, v_sections_impl, v_sections_total;
end;
$smoke$;
