-- ============================================================================
-- R.5A.B.7 — context_detail_descriptor(p_context_actor_id) consolidated RPC
-- ============================================================================
-- Mismo patron que B.6 pero para Context. Une B.4C (sections+widgets) +
-- context_available_actions + my_permissions + previews (members/resources/
-- events/decisions/obligations/documents/activity).
--
-- Filtrado dinamico de sections/widgets:
--   - sections: required_permission must be in my_permissions (or NULL = visible)
--   - widgets: same
--
-- context_subtype = actors.actor_subtype (fallback a 'generic' si no mapeado).
-- ============================================================================

create or replace function public.context_detail_descriptor(p_context_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
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
begin
  if auth.uid() is null then raise exception 'unauthenticated' using errcode='42501'; end if;
  v_actor := public.current_actor_id();
  if v_actor is null then raise exception 'missing person actor' using errcode='42501'; end if;

  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context' using errcode='42501';
  end if;

  select to_jsonb(a.*), a.actor_subtype
    into v_context, v_actor_subtype
    from public.actors a where a.id = p_context_actor_id and a.is_context = true;
  if v_context is null then
    raise exception 'context not found' using errcode='P0002';
  end if;
  v_actor_subtype := coalesce(v_actor_subtype, 'generic');

  select to_jsonb(m.*) into v_membership
    from public.actor_memberships m
   where m.context_actor_id = p_context_actor_id
     and m.member_actor_id = v_actor
     and m.membership_status = 'active'
   limit 1;

  select coalesce(array_agg(distinct rp.permission_key), array[]::text[])
    into v_my_perms
    from public.role_assignments ra
    join public.role_permissions rp on rp.role_id = ra.role_id and rp.allowed
   where ra.context_actor_id = p_context_actor_id and ra.member_actor_id = v_actor;

  select coalesce(jsonb_agg(jsonb_build_object(
           'role_key', r.role_key,
           'display_name', r.display_name,
           'description', r.description,
           'member_count', (
             select count(*) from public.role_assignments ra2 where ra2.role_id = r.id
           )
         ) order by r.role_key), '[]'::jsonb)
    into v_roles
    from public.roles r
   where r.context_actor_id = p_context_actor_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'section_key', cs.section_key,
           'display_name', csc.display_name,
           'icon', csc.icon,
           'sort_order', cs.sort_order,
           'visible', true,
           'required_permission', cs.required_permission,
           'visible_when_status', cs.visible_when_status
         ) order by cs.sort_order, cs.section_key), '[]'::jsonb)
    into v_sections
    from public.context_subtype_sections cs
    join public.context_section_catalog csc on csc.section_key = cs.section_key
   where cs.context_subtype = v_actor_subtype
     and (cs.required_permission is null or cs.required_permission = any(v_my_perms));

  if jsonb_array_length(v_sections) = 0 then
    select coalesce(jsonb_agg(jsonb_build_object(
             'section_key', cs.section_key,
             'display_name', csc.display_name,
             'icon', csc.icon,
             'sort_order', cs.sort_order,
             'visible', true,
             'required_permission', cs.required_permission,
             'visible_when_status', cs.visible_when_status
           ) order by cs.sort_order, cs.section_key), '[]'::jsonb)
      into v_sections
      from public.context_subtype_sections cs
      join public.context_section_catalog csc on csc.section_key = cs.section_key
     where cs.context_subtype = 'generic'
       and (cs.required_permission is null or cs.required_permission = any(v_my_perms));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'widget_key', cw.widget_key,
           'display_name', cdw.display_name,
           'icon', cdw.icon,
           'data_source_key', cdw.data_source_key,
           'sort_order', cw.sort_order
         ) order by cw.sort_order, cw.widget_key), '[]'::jsonb)
    into v_widgets
    from public.context_subtype_widgets cw
    join public.context_dashboard_widgets cdw on cdw.widget_key = cw.widget_key
   where cw.context_subtype = v_actor_subtype
     and (cw.required_permission is null or cw.required_permission = any(v_my_perms));

  if jsonb_array_length(v_widgets) = 0 then
    select coalesce(jsonb_agg(jsonb_build_object(
             'widget_key', cw.widget_key,
             'display_name', cdw.display_name,
             'icon', cdw.icon,
             'data_source_key', cdw.data_source_key,
             'sort_order', cw.sort_order
           ) order by cw.sort_order, cw.widget_key), '[]'::jsonb)
      into v_widgets
      from public.context_subtype_widgets cw
      join public.context_dashboard_widgets cdw on cdw.widget_key = cw.widget_key
     where cw.context_subtype = 'generic'
       and (cw.required_permission is null or cw.required_permission = any(v_my_perms));
  end if;

  v_actions_raw := public.context_available_actions(p_context_actor_id, v_actor);
  v_actions := coalesce(v_actions_raw, '[]'::jsonb);

  v_metrics := jsonb_build_object(
    'member_count', (
      select count(*) from public.actor_memberships
       where context_actor_id = p_context_actor_id and membership_status = 'active'
    ),
    'resource_count_by_class', coalesce((
      select jsonb_object_agg(coalesce(resource_class_key,'generic'), n)
        from (
          select resource_class_key, count(*) as n
            from public.resources
           where canonical_owner_actor_id = p_context_actor_id and archived_at is null
           group by resource_class_key
        ) g
    ), '{}'::jsonb),
    'pending_decisions', (
      select count(*) from public.decisions
       where context_actor_id = p_context_actor_id and status = 'open'
    ),
    'open_obligations', (
      select count(*) from public.obligations
       where context_actor_id = p_context_actor_id and status in ('open','pending','accepted')
    ),
    'balance_by_currency', '{}'::jsonb
  );

  select coalesce(jsonb_agg(jsonb_build_object(
           'actor_id', a.id,
           'display_name', a.display_name,
           'membership_type', m.membership_type,
           'joined_at', m.joined_at
         ) order by m.joined_at desc), '[]'::jsonb)
    into v_members_preview
    from (
      select * from public.actor_memberships
       where context_actor_id = p_context_actor_id and membership_status='active'
       order by joined_at desc limit 8
    ) m
    join public.actors a on a.id = m.member_actor_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'resource_id', r.id,
           'display_name', r.display_name,
           'class_key', r.resource_class_key,
           'subtype_key', r.resource_subtype_key,
           'status', r.status
         ) order by r.created_at desc), '[]'::jsonb)
    into v_resources_preview
    from (
      select * from public.resources
       where canonical_owner_actor_id = p_context_actor_id and archived_at is null
       order by created_at desc limit 8
    ) r;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_id', ce.id,
           'title', ce.title,
           'event_type', ce.event_type,
           'starts_at', ce.starts_at,
           'status', ce.status
         ) order by ce.starts_at asc), '[]'::jsonb)
    into v_events_preview
    from (
      select * from public.calendar_events
       where context_actor_id = p_context_actor_id and status <> 'cancelled'
         and starts_at >= now() - interval '1 day'
       order by starts_at asc limit 5
    ) ce;

  v_money_preview := jsonb_build_object(
    'my_balance', null,
    'open_settlements', (
      select count(*) from public.obligations
       where context_actor_id = p_context_actor_id and status='open'
         and (debtor_actor_id = v_actor or creditor_actor_id = v_actor)
    )
  );

  select coalesce(jsonb_agg(jsonb_build_object(
           'obligation_id', o.id,
           'kind', coalesce(o.obligation_kind, o.obligation_type),
           'amount', o.amount,
           'currency', o.currency,
           'status', o.status
         ) order by o.created_at desc), '[]'::jsonb)
    into v_obligations_preview
    from (
      select * from public.obligations
       where context_actor_id = p_context_actor_id and status in ('open','pending','accepted')
       order by created_at desc limit 5
    ) o;

  select coalesce(jsonb_agg(jsonb_build_object(
           'decision_id', d.id,
           'title', d.title,
           'decision_type', d.decision_type,
           'status', d.status,
           'closes_at', d.closes_at
         ) order by d.created_at desc), '[]'::jsonb)
    into v_decisions_preview
    from (
      select * from public.decisions
       where context_actor_id = p_context_actor_id and status='open'
       order by created_at desc limit 5
    ) d;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', dd.id,
           'title', dd.title,
           'document_type', dd.document_type,
           'created_at', dd.created_at
         ) order by dd.created_at desc), '[]'::jsonb)
    into v_documents_preview
    from (
      select * from public.documents
       where context_actor_id = p_context_actor_id and archived_at is null
       order by created_at desc limit 5
    ) dd;

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
       where context_actor_id = p_context_actor_id
       order by occurred_at desc limit 10
    ) ae;

  return jsonb_build_object(
    'context', v_context,
    'membership', coalesce(v_membership, '{}'::jsonb) || jsonb_build_object('my_permissions', to_jsonb(v_my_perms)),
    'roles', v_roles,
    'permissions', to_jsonb(v_my_perms),
    'sections', v_sections,
    'widgets', v_widgets,
    'actions', v_actions,
    'metrics', v_metrics,
    'members_preview', v_members_preview,
    'resources_preview', v_resources_preview,
    'events_preview', v_events_preview,
    'money_preview', v_money_preview,
    'obligations_preview', v_obligations_preview,
    'decisions_preview', v_decisions_preview,
    'documents_preview', v_documents_preview,
    'activity_preview', v_activity_preview
  );
end;
$$;

comment on function public.context_detail_descriptor(uuid) is
  'R.5A.B.7: descriptor consolidado de Context. Une membership + my_permissions + roles + sections (filtradas por my_perms) + widgets + actions + metrics + 8 previews. Fallback a context_subtype generic si actor_subtype no esta seedeado.';

revoke all on function public.context_detail_descriptor(uuid) from public, anon;
grant execute on function public.context_detail_descriptor(uuid) to authenticated, service_role;
