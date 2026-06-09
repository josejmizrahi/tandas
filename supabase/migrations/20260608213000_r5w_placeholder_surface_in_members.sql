-- R.5W.placeholder.surface (2026-06-08) — exponer is_placeholder + contact_phone
-- en members de context_summary y members_preview de context_detail_descriptor.
-- iOS lo usa para mostrar badge "Sin app" en MembersListView + opcional
-- secondary line con phone/email del placeholder.
--
-- Cero cambio en lógica. Sólo agrega 3 campos al jsonb_build_object de
-- members en context_summary y 1 campo (is_placeholder) a members_preview
-- de context_detail_descriptor.

-- (full bodies replicated for safety — only relevant section comments noted)

CREATE OR REPLACE FUNCTION public.context_summary(p_context_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
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
    'members_count', (select count(*) from public.actor_memberships
                      where context_actor_id = p_context_actor_id and membership_status = 'active'),
    'resources_count', (select count(*) from public.resources
                        where canonical_owner_actor_id = p_context_actor_id and archived_at is null),
    'pending_decisions', (select count(*) from public.decisions
                          where context_actor_id = p_context_actor_id and status = 'open'),
    'open_obligations', (select count(*) from public.obligations
                         where context_actor_id = p_context_actor_id and status = 'open'),
    -- R.5W: is_placeholder + contact_phone + contact_email surface here.
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'actor_id', m.member_actor_id, 'display_name', a.display_name,
        'membership_type', m.membership_type, 'joined_at', m.joined_at,
        'is_placeholder', a.is_placeholder,
        'contact_phone', a.contact_phone,
        'contact_email', a.contact_email,
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
        'payload', d.payload, 'created_at', d.created_at) order by d.created_at desc)
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
            order by occurred_at desc limit 20) ae), '[]'::jsonb),
    'available_actions', public.context_available_actions(p_context_actor_id, v_caller)
  );
end; $function$;

-- context_detail_descriptor: only members_preview gains is_placeholder.
-- Full body replicated for atomicity.

CREATE OR REPLACE FUNCTION public.context_detail_descriptor(p_context_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor uuid;
  v_context jsonb;
  v_actor_subtype text;
  v_membership jsonb;
  v_my_perms text[];
  v_roles jsonb;
  v_sections jsonb;
  v_widgets jsonb;
  v_actions jsonb;
  v_actions_raw jsonb;
  v_metrics jsonb;
  v_members_preview jsonb;
  v_resources_preview jsonb;
  v_events_preview jsonb;
  v_money_preview jsonb;
  v_obligations_preview jsonb;
  v_decisions_preview jsonb;
  v_documents_preview jsonb;
  v_activity_preview jsonb;
  v_child_contexts_preview jsonb;
  v_pending_invitations_preview jsonb;
  v_my_balance_by_currency jsonb;
  v_conflicts jsonb;
  v_conflicts_open integer;
  v_conflicts_total integer;
  v_conflicts_critical integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='42501'; END IF;
  v_actor := public.current_actor_id();
  IF v_actor IS NULL THEN RAISE EXCEPTION 'missing person actor' USING ERRCODE='42501'; END IF;
  IF NOT public.is_context_member(p_context_actor_id) THEN
    RAISE EXCEPTION 'not a member of context' USING ERRCODE='42501';
  END IF;

  SELECT to_jsonb(a.*), a.actor_subtype INTO v_context, v_actor_subtype
    FROM public.actors a WHERE a.id = p_context_actor_id AND a.is_context = true;
  IF v_context IS NULL THEN RAISE EXCEPTION 'context not found' USING ERRCODE='P0002'; END IF;
  v_actor_subtype := coalesce(v_actor_subtype, 'generic');

  SELECT to_jsonb(m.*) INTO v_membership
    FROM public.actor_memberships m
   WHERE m.context_actor_id = p_context_actor_id AND m.member_actor_id = v_actor
     AND m.membership_status = 'active' LIMIT 1;

  SELECT coalesce(array_agg(DISTINCT rp.permission_key), array[]::text[]) INTO v_my_perms
    FROM public.role_assignments ra
    JOIN public.role_permissions rp ON rp.role_id = ra.role_id AND rp.allowed
   WHERE ra.context_actor_id = p_context_actor_id AND ra.member_actor_id = v_actor;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'role_key', r.role_key, 'display_name', r.display_name,
           'description', r.description,
           'member_count', (SELECT count(*) FROM public.role_assignments ra2 WHERE ra2.role_id = r.id)
         ) ORDER BY r.role_key), '[]'::jsonb)
    INTO v_roles FROM public.roles r WHERE r.context_actor_id = p_context_actor_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'section_key', cs.section_key, 'display_name', csc.display_name,
           'icon', csc.icon, 'sort_order', cs.sort_order, 'visible', true,
           'required_permission', cs.required_permission, 'visible_when_status', cs.visible_when_status
         ) ORDER BY cs.sort_order, cs.section_key), '[]'::jsonb)
    INTO v_sections
    FROM public.context_subtype_sections cs
    JOIN public.context_section_catalog csc ON csc.section_key = cs.section_key
   WHERE cs.context_subtype = v_actor_subtype
     AND (cs.required_permission IS NULL OR cs.required_permission = ANY(v_my_perms));

  IF jsonb_array_length(v_sections) = 0 THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'section_key', cs.section_key, 'display_name', csc.display_name,
             'icon', csc.icon, 'sort_order', cs.sort_order, 'visible', true,
             'required_permission', cs.required_permission, 'visible_when_status', cs.visible_when_status
           ) ORDER BY cs.sort_order, cs.section_key), '[]'::jsonb)
      INTO v_sections
      FROM public.context_subtype_sections cs
      JOIN public.context_section_catalog csc ON csc.section_key = cs.section_key
     WHERE cs.context_subtype = 'generic'
       AND (cs.required_permission IS NULL OR cs.required_permission = ANY(v_my_perms));
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'widget_key', cw.widget_key, 'display_name', cdw.display_name,
           'icon', cdw.icon, 'data_source_key', cdw.data_source_key, 'sort_order', cw.sort_order
         ) ORDER BY cw.sort_order, cw.widget_key), '[]'::jsonb)
    INTO v_widgets
    FROM public.context_subtype_widgets cw
    JOIN public.context_dashboard_widgets cdw ON cdw.widget_key = cw.widget_key
   WHERE cw.context_subtype = v_actor_subtype
     AND (cw.required_permission IS NULL OR cw.required_permission = ANY(v_my_perms));

  IF jsonb_array_length(v_widgets) = 0 THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'widget_key', cw.widget_key, 'display_name', cdw.display_name,
             'icon', cdw.icon, 'data_source_key', cdw.data_source_key, 'sort_order', cw.sort_order
           ) ORDER BY cw.sort_order, cw.widget_key), '[]'::jsonb)
      INTO v_widgets
      FROM public.context_subtype_widgets cw
      JOIN public.context_dashboard_widgets cdw ON cdw.widget_key = cw.widget_key
     WHERE cw.context_subtype = 'generic'
       AND (cw.required_permission IS NULL OR cw.required_permission = ANY(v_my_perms));
  END IF;

  v_actions_raw := public.context_available_actions(p_context_actor_id, v_actor);
  v_actions := coalesce(v_actions_raw, '[]'::jsonb);

  v_metrics := jsonb_build_object(
    'member_count', (SELECT count(*) FROM public.actor_memberships
                      WHERE context_actor_id = p_context_actor_id AND membership_status = 'active'),
    'resource_count_by_class', coalesce((
      SELECT jsonb_object_agg(coalesce(resource_class_key,'generic'), n) FROM (
        SELECT resource_class_key, count(*) AS n FROM public.resources
         WHERE canonical_owner_actor_id = p_context_actor_id AND archived_at IS NULL
         GROUP BY resource_class_key) g
    ), '{}'::jsonb),
    'pending_decisions', (SELECT count(*) FROM public.decisions
                           WHERE context_actor_id = p_context_actor_id AND status = 'open'),
    'open_obligations', (SELECT count(*) FROM public.obligations
                          WHERE context_actor_id = p_context_actor_id
                            AND status IN ('open','pending','accepted')),
    'balance_by_currency', '{}'::jsonb
  );

  -- R.5W: include is_placeholder in members_preview.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'actor_id', a.id, 'display_name', a.display_name,
           'membership_type', m.membership_type, 'joined_at', m.joined_at,
           'is_placeholder', a.is_placeholder
         ) ORDER BY m.joined_at DESC), '[]'::jsonb)
    INTO v_members_preview
    FROM (SELECT * FROM public.actor_memberships
           WHERE context_actor_id = p_context_actor_id AND membership_status='active'
           ORDER BY joined_at DESC LIMIT 8) m
    JOIN public.actors a ON a.id = m.member_actor_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'resource_id', r.id, 'display_name', r.display_name,
           'class_key', r.resource_class_key, 'subtype_key', r.resource_subtype_key,
           'status', r.status
         ) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_resources_preview
    FROM (SELECT * FROM public.resources
           WHERE canonical_owner_actor_id = p_context_actor_id AND archived_at IS NULL
           ORDER BY created_at DESC LIMIT 8) r;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'event_id', ce.id, 'title', ce.title, 'event_type', ce.event_type,
           'starts_at', ce.starts_at, 'status', ce.status
         ) ORDER BY ce.starts_at ASC), '[]'::jsonb)
    INTO v_events_preview
    FROM (SELECT * FROM public.calendar_events
           WHERE context_actor_id = p_context_actor_id AND status <> 'cancelled'
             AND starts_at >= now() - interval '1 day'
           ORDER BY starts_at ASC LIMIT 5) ce;

  SELECT coalesce(jsonb_object_agg(b.currency, b.net_balance), '{}'::jsonb) INTO v_my_balance_by_currency
    FROM public.actor_money_balances b
   WHERE b.context_actor_id = p_context_actor_id AND b.actor_id = v_actor;

  v_money_preview := jsonb_build_object(
    'my_balance', null, 'my_balance_by_currency', v_my_balance_by_currency,
    'open_settlements', (SELECT count(*) FROM public.obligations
                          WHERE context_actor_id = p_context_actor_id AND status='open'
                            AND (debtor_actor_id = v_actor OR creditor_actor_id = v_actor))
  );

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'obligation_id', o.id, 'kind', coalesce(o.obligation_kind, o.obligation_type),
           'amount', o.amount, 'currency', o.currency, 'status', o.status
         ) ORDER BY o.created_at DESC), '[]'::jsonb)
    INTO v_obligations_preview
    FROM (SELECT * FROM public.obligations
           WHERE context_actor_id = p_context_actor_id AND status IN ('open','pending','accepted')
           ORDER BY created_at DESC LIMIT 5) o;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'decision_id', d.id, 'title', d.title, 'decision_type', d.decision_type,
           'status', d.status, 'closes_at', d.closes_at
         ) ORDER BY d.created_at DESC), '[]'::jsonb)
    INTO v_decisions_preview
    FROM (SELECT * FROM public.decisions
           WHERE context_actor_id = p_context_actor_id AND status='open'
           ORDER BY created_at DESC LIMIT 5) d;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', dd.id, 'title', dd.title,
           'document_type', dd.document_type, 'created_at', dd.created_at
         ) ORDER BY dd.created_at DESC), '[]'::jsonb)
    INTO v_documents_preview
    FROM (SELECT * FROM public.documents
           WHERE context_actor_id = p_context_actor_id AND archived_at IS NULL
           ORDER BY created_at DESC LIMIT 5) dd;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'event_id', ae.id, 'event_type', ae.event_type, 'actor_id', ae.actor_id,
           'payload', ae.payload, 'occurred_at', ae.occurred_at
         ) ORDER BY ae.occurred_at DESC), '[]'::jsonb)
    INTO v_activity_preview
    FROM (SELECT * FROM public.activity_events
           WHERE context_actor_id = p_context_actor_id
           ORDER BY occurred_at DESC LIMIT 10) ae;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'display_name', a.display_name,
           'actor_kind', a.actor_kind, 'actor_subtype', a.actor_subtype,
           'visibility', a.visibility, 'linked_at', ar.created_at
         ) ORDER BY a.display_name), '[]'::jsonb)
    INTO v_child_contexts_preview
    FROM public.actor_relationships ar
    JOIN public.actors a ON a.id = ar.object_actor_id
   WHERE ar.subject_actor_id = p_context_actor_id
     AND ar.relationship_type = 'contains'
     AND (ar.ends_at IS NULL OR ar.ends_at > now())
     AND a.archived_at IS NULL AND a.actor_kind IN ('collective','legal_entity');

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'invite_id', ci.id, 'code', ci.code,
           'max_uses', ci.max_uses, 'used_count', ci.used_count,
           'expires_at', ci.expires_at, 'created_at', ci.created_at
         ) ORDER BY ci.created_at DESC), '[]'::jsonb)
    INTO v_pending_invitations_preview
    FROM public.context_invites ci
   WHERE ci.context_actor_id = p_context_actor_id AND ci.status='active'
     AND (ci.expires_at IS NULL OR ci.expires_at > now())
     AND (ci.max_uses IS NULL OR ci.used_count < ci.max_uses);

  SELECT
    count(*) FILTER (WHERE status='open'),
    count(*),
    count(*) FILTER (WHERE status='open' AND severity='critical')
  INTO v_conflicts_open, v_conflicts_total, v_conflicts_critical
  FROM (
    SELECT rc.status, rc.severity,
      row_number() OVER (
        PARTITION BY rc.resource_id, rc.conflict_type,
                     coalesce(rc.payload->>'reservation_a_id', rc.source_id::text),
                     coalesce(rc.payload->>'reservation_b_id','')
        ORDER BY CASE rc.source_type WHEN 'reservation_conflict' THEN 1
                                     WHEN 'reservation_pair' THEN 2 ELSE 3 END,
                 rc.detected_at DESC
      ) AS rn
    FROM public.resource_conflicts rc
    WHERE rc.context_actor_id = p_context_actor_id
  ) deduped
  WHERE rn = 1;

  v_conflicts := jsonb_build_object(
    'context_actor_id', p_context_actor_id,
    'open_count',     coalesce(v_conflicts_open, 0),
    'critical_count', coalesce(v_conflicts_critical, 0),
    'total_count',    coalesce(v_conflicts_total, 0)
  );

  v_sections := public._r5b_strip_conflicts_section_if_clean(v_sections, coalesce(v_conflicts_open, 0));
  v_widgets  := public._r5b_strip_conflicts_widget_if_clean(v_widgets,  coalesce(v_conflicts_open, 0));

  RETURN jsonb_build_object(
    'context', v_context,
    'membership', coalesce(v_membership, '{}'::jsonb) || jsonb_build_object('my_permissions', to_jsonb(v_my_perms)),
    'roles', v_roles, 'permissions', to_jsonb(v_my_perms),
    'sections', v_sections, 'widgets', v_widgets, 'actions', v_actions,
    'metrics', v_metrics,
    'members_preview', v_members_preview, 'resources_preview', v_resources_preview,
    'events_preview', v_events_preview, 'money_preview', v_money_preview,
    'obligations_preview', v_obligations_preview, 'decisions_preview', v_decisions_preview,
    'documents_preview', v_documents_preview, 'activity_preview', v_activity_preview,
    'child_contexts_preview', v_child_contexts_preview,
    'pending_invitations_preview', v_pending_invitations_preview,
    'conflicts', v_conflicts
  );
END;
$function$;
