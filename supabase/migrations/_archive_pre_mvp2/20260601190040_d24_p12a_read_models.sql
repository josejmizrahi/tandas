-- d24_p12a_read_models
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- =====================================================================
-- V3 D.24 PHASE 12A — Read Models (backend-only)
--
-- 6 RPCs estables que iOS puede consumir en lugar de hacer N round-trips
-- + reconstrucción cliente-side. NO refactor iOS (P12B).
--
-- Todas SECURITY DEFINER + STABLE + member gate.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. group_home_summary(p_group_id) returns jsonb
--    Hidrata el Home en 1 round-trip.
-- ---------------------------------------------------------------------

create or replace function public.group_home_summary(p_group_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public, pg_catalog
as $$
declare
    v_uid uuid := (select auth.uid());
    v_group public.groups%ROWTYPE;
    v_membership public.group_memberships%ROWTYPE;
    v_perms jsonb;
    v_recent jsonb;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_group from public.groups where id = p_group_id;
    if v_group.id is null then raise exception 'group_not_found' using errcode='42704'; end if;
    if not public.is_group_member(p_group_id) then raise exception 'not_a_member' using errcode='42501'; end if;

    select * into v_membership from public.group_memberships
    where group_id=p_group_id and user_id=v_uid and status='active' limit 1;

    select coalesce(jsonb_agg(grp.permission_key order by grp.permission_key), '[]'::jsonb)
    into v_perms
    from public.group_member_roles gmr
    join public.group_role_permissions grp on grp.role_id = gmr.role_id
    where gmr.membership_id = v_membership.id;

    select coalesce(jsonb_agg(jsonb_build_object(
        'event_uuid', e.uuid_id,
        'event_type', e.event_type,
        'entity_kind', e.entity_kind,
        'entity_id', e.entity_id,
        'summary', e.summary,
        'occurred_at', e.occurred_at,
        'actor_user_id', e.actor_user_id
    ) order by e.occurred_at desc), '[]'::jsonb)
    into v_recent
    from (select * from public.group_events
          where group_id = p_group_id
          order by occurred_at desc, id desc
          limit 10) e;

    return jsonb_build_object(
        'group', to_jsonb(v_group) - 'metadata',
        'my_membership', to_jsonb(v_membership),
        'permissions', v_perms,
        'open_decisions_count', (
            select count(*) from public.group_decisions
            where group_id = p_group_id and status = 'open'
        ),
        'open_obligations_count', (
            select count(*) from public.group_obligations
            where group_id = p_group_id and amount_outstanding > 0
        ),
        'upcoming_events_count', (
            select count(*) from public.group_resources r
            join public.group_resource_events e on e.resource_id = r.id
            where r.group_id = p_group_id and r.resource_type='event'
              and r.archived_at is null and e.cancelled_at is null
              and e.starts_at >= now()
        ),
        'recent_activity', v_recent,
        'caller_membership_id', v_membership.id,
        'caller_user_id', v_uid
    );
end$$;

grant execute on function public.group_home_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2. resource_detail_summary(p_resource_id) returns jsonb
-- ---------------------------------------------------------------------

create or replace function public.resource_detail_summary(p_resource_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public, pg_catalog
as $$
declare
    v_uid uuid := (select auth.uid());
    v_r public.group_resources%ROWTYPE;
    v_owners jsonb;
    v_capabilities jsonb;
    v_recent jsonb;
    v_subtype jsonb;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_r from public.group_resources where id = p_resource_id;
    if v_r.id is null then raise exception 'resource_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_r.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;

    -- Subtype payload (polymorphic) — fetch from the matching subtype table.
    v_subtype := case v_r.resource_type
        when 'event'     then (select to_jsonb(x) from public.group_resource_events x where x.resource_id=p_resource_id)
        when 'asset'     then (select to_jsonb(x) from public.group_resource_assets x where x.resource_id=p_resource_id)
        when 'fund'      then (select to_jsonb(x) from public.group_resource_funds x where x.resource_id=p_resource_id)
        when 'space'     then (select to_jsonb(x) from public.group_resource_spaces x where x.resource_id=p_resource_id)
        when 'slot'      then (select to_jsonb(x) from public.group_resource_slots x where x.resource_id=p_resource_id)
        when 'right'     then (select to_jsonb(x) from public.group_resource_rights x where x.resource_id=p_resource_id)
        else null
    end;

    select coalesce(jsonb_agg(jsonb_build_object(
        'id', o.id,
        'owner_kind', o.owner_kind,
        'membership_id', o.membership_id,
        'external_party_id', o.external_party_id,
        'ownership_pct', o.ownership_pct,
        'ownership_role', o.ownership_role,
        'starts_at', o.starts_at,
        'ends_at', o.ends_at,
        'source_decision_id', o.source_decision_id,
        'display_name', coalesce(p.display_name, p.username, ep.display_name)
    ) order by o.starts_at desc), '[]'::jsonb)
    into v_owners
    from public.group_resource_owners o
    left join public.group_memberships gm on gm.id = o.membership_id
    left join public.profiles p on p.id = gm.user_id
    left join public.group_external_parties ep on ep.id = o.external_party_id
    where o.resource_id = p_resource_id and o.ends_at is null;

    select coalesce(jsonb_agg(jsonb_build_object(
        'capability_key', c.capability_key,
        'enabled', c.enabled,
        'config', c.config,
        'updated_at', c.updated_at
    )), '[]'::jsonb)
    into v_capabilities
    from public.group_resource_capabilities c
    where c.resource_id = p_resource_id;

    select coalesce(jsonb_agg(jsonb_build_object(
        'event_uuid', e.uuid_id,
        'event_type', e.event_type,
        'summary', e.summary,
        'occurred_at', e.occurred_at,
        'actor_user_id', e.actor_user_id
    ) order by e.occurred_at desc), '[]'::jsonb)
    into v_recent
    from (select * from public.group_events
          where group_id = v_r.group_id and entity_kind='resource' and entity_id=p_resource_id
          order by occurred_at desc, id desc
          limit 10) e;

    return jsonb_build_object(
        'resource', to_jsonb(v_r),
        'subtype', coalesce(v_subtype, '{}'::jsonb),
        'owners', v_owners,
        'capabilities', v_capabilities,
        'comments_count', (
            select count(*) from public.group_comments
            where group_id=v_r.group_id AND entity_kind='resource' AND entity_id=p_resource_id
              AND status='active'
        ),
        'attachments_count', (
            select count(*) from public.group_attachments
            where group_id=v_r.group_id AND entity_kind='resource' AND entity_id=p_resource_id
              AND status='active'
        ),
        'open_obligations_count', (
            select count(*) from public.group_obligations
            where group_id=v_r.group_id AND source_resource_id=p_resource_id
              AND amount_outstanding > 0
        ),
        'recent_activity', v_recent
    );
end$$;

grant execute on function public.resource_detail_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. event_detail_summary(p_event_id) returns jsonb
--    Reuses get_event_detail (D.24 P1) shape and adds counts.
-- ---------------------------------------------------------------------

create or replace function public.event_detail_summary(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public, pg_catalog
as $$
declare
    v_detail jsonb;
    v_r public.group_resources%ROWTYPE;
begin
    select * into v_r from public.group_resources where id=p_event_id and resource_type='event';
    if v_r.id is null then raise exception 'event_not_found' using errcode='42704'; end if;

    v_detail := public.get_event_detail(p_event_id);

    return v_detail || jsonb_build_object(
        'comments_count', (
            select count(*) from public.group_comments
            where group_id=v_r.group_id AND entity_kind='event' AND entity_id=p_event_id
              AND status='active'
        ),
        'attachments_count', (
            select count(*) from public.group_attachments
            where group_id=v_r.group_id AND entity_kind='event' AND entity_id=p_event_id
              AND status='active'
        )
    );
end$$;

grant execute on function public.event_detail_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. decision_live_result(p_decision_id) returns jsonb
-- ---------------------------------------------------------------------

create or replace function public.decision_live_result(p_decision_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public, pg_catalog
as $$
declare
    v_uid uuid := (select auth.uid());
    v_d public.group_decisions%ROWTYPE;
    v_my_membership_id uuid;
    v_my_vote jsonb;
    v_counts jsonb;
    v_eligible int;
    v_total_votes int;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_d from public.group_decisions where id=p_decision_id;
    if v_d.id is null then raise exception 'decision_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_d.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;

    select id into v_my_membership_id from public.group_memberships
    where group_id=v_d.group_id and user_id=v_uid and status='active' limit 1;

    -- Latest vote per membership (append-only model: keep newest by cast_at)
    with latest as (
        select distinct on (membership_id) membership_id, vote_value, cast_at
        from public.group_votes
        where decision_id = p_decision_id
        order by membership_id, cast_at desc, id desc
    )
    select jsonb_build_object(
        'yes', count(*) filter (where vote_value='yes'),
        'no',  count(*) filter (where vote_value='no'),
        'abstain', count(*) filter (where vote_value='abstain'),
        'maybe', count(*) filter (where vote_value='maybe'),
        'total', count(*)
    ) into v_counts
    from latest;

    v_total_votes := coalesce((v_counts->>'total')::int, 0);

    -- Eligible = active memberships
    select count(*) into v_eligible from public.group_memberships
    where group_id=v_d.group_id and status='active';

    -- My vote (latest)
    select jsonb_build_object(
        'vote_value', vote_value,
        'cast_at', cast_at,
        'reason', reason
    ) into v_my_vote
    from public.group_votes
    where decision_id=p_decision_id and membership_id=v_my_membership_id
    order by cast_at desc, id desc limit 1;

    return jsonb_build_object(
        'decision', to_jsonb(v_d),
        'current_vote_counts', coalesce(v_counts, jsonb_build_object('yes',0,'no',0,'abstain',0,'maybe',0,'total',0)),
        'my_vote', coalesce(v_my_vote, 'null'::jsonb),
        'eligible_voters_count', v_eligible,
        'quorum_status', jsonb_build_object(
            'required_pct', v_d.quorum_pct,
            'current_pct', case when v_eligible=0 then 0
                               else round((v_total_votes::numeric * 100.0 / v_eligible)::numeric, 2) end,
            'reached', case when v_eligible=0 then false
                            else (v_total_votes::numeric * 100.0 / v_eligible) >= coalesce(v_d.quorum_pct, 0) end
        ),
        'threshold_status', jsonb_build_object(
            'required_pct', v_d.threshold_pct,
            'current_yes_pct', case when v_total_votes=0 then 0
                                else round(((v_counts->>'yes')::numeric * 100.0 / v_total_votes)::numeric, 2) end,
            'reached', case when v_total_votes=0 then false
                            else ((v_counts->>'yes')::numeric * 100.0 / v_total_votes) >= coalesce(v_d.threshold_pct, 50) end
        ),
        'execution_status', v_d.execution_status,
        'execution_attempts', v_d.execution_attempts,
        'execution_error', v_d.execution_error
    );
end$$;

grant execute on function public.decision_live_result(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. member_balance_summary(p_group_id, p_membership_id) returns jsonb
-- ---------------------------------------------------------------------

create or replace function public.member_balance_summary(p_group_id uuid, p_membership_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public, pg_catalog
as $$
declare
    v_uid uuid := (select auth.uid());
    v_member public.group_memberships%ROWTYPE;
    v_owed_by_me numeric := 0;
    v_owed_to_me numeric := 0;
    v_recent jsonb;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_member from public.group_memberships where id=p_membership_id and group_id=p_group_id;
    if v_member.id is null then raise exception 'member_not_found' using errcode='42704'; end if;
    if not public.is_group_member(p_group_id) then raise exception 'not_a_member' using errcode='42501'; end if;

    -- Member owes
    select coalesce(sum(amount_outstanding), 0) into v_owed_by_me
    from public.group_obligations
    where group_id=p_group_id and owed_by_membership_id=p_membership_id
      and amount_outstanding > 0;

    -- Others owe to member
    select coalesce(sum(amount_outstanding), 0) into v_owed_to_me
    from public.group_obligations
    where group_id=p_group_id and owed_to_membership_id=p_membership_id
      and amount_outstanding > 0;

    -- Recent settlements
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id,
        'paid_by_membership_id', s.paid_by_membership_id,
        'paid_to_membership_id', s.paid_to_membership_id,
        'paid_to_kind', s.paid_to_kind,
        'amount', s.amount,
        'unit', s.unit,
        'status', s.status,
        'created_at', s.created_at
    ) order by s.created_at desc), '[]'::jsonb)
    into v_recent
    from (select * from public.group_settlements
          where group_id=p_group_id
            and (paid_by_membership_id=p_membership_id or paid_to_membership_id=p_membership_id)
          order by created_at desc
          limit 10) s;

    return jsonb_build_object(
        'membership', to_jsonb(v_member),
        'owed_by', v_owed_by_me,
        'owed_to', v_owed_to_me,
        'net_balance', v_owed_to_me - v_owed_by_me,
        'open_obligations_count', (
            select count(*) from public.group_obligations
            where group_id=p_group_id
              and (owed_by_membership_id=p_membership_id or owed_to_membership_id=p_membership_id)
              and amount_outstanding > 0
        ),
        'recent_settlements', v_recent
    );
end$$;

grant execute on function public.member_balance_summary(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. activity_feed(p_group_id, p_limit, p_before?) returns jsonb
-- ---------------------------------------------------------------------

create or replace function public.activity_feed(
    p_group_id uuid,
    p_limit integer default 50,
    p_before timestamptz default null
) returns jsonb
language plpgsql stable security definer set search_path=public, pg_catalog
as $$
declare
    v_uid uuid := (select auth.uid());
    v_items jsonb;
    v_next_before timestamptz;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    if not public.is_group_member(p_group_id) then raise exception 'not_a_member' using errcode='42501'; end if;

    select coalesce(jsonb_agg(jsonb_build_object(
        'event_uuid', e.uuid_id,
        'event_type', e.event_type,
        'entity_kind', e.entity_kind,
        'entity_id', e.entity_id,
        'summary', e.summary,
        'payload', e.payload,
        'occurred_at', e.occurred_at,
        'actor_user_id', e.actor_user_id,
        'actor_display_name', coalesce(p.display_name, p.username)
    ) order by e.occurred_at desc), '[]'::jsonb),
           min(e.occurred_at)
    into v_items, v_next_before
    from (
        select * from public.group_events
        where group_id = p_group_id
          and (p_before is null or occurred_at < p_before)
        order by occurred_at desc, id desc
        limit greatest(coalesce(p_limit, 50), 1)
    ) e
    left join public.profiles p on p.id = e.actor_user_id;

    return jsonb_build_object(
        'items', v_items,
        'next_before', v_next_before,
        'limit', p_limit
    );
end$$;

grant execute on function public.activity_feed(uuid, integer, timestamptz) to authenticated;
