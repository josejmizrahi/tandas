-- d24_p8_fix_decision_rules_read
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- Hot-fix: groups.decision_rules jsonb es la fuente, no tabla separada.
create or replace function public.start_sanction_appeal(
    p_sanction_id uuid, p_reason text, p_client_id text default null
) returns uuid language plpgsql security definer set search_path=public, pg_catalog as $$
declare
    v_uid uuid := (select auth.uid());
    v_s public.group_sanctions%ROWTYPE;
    v_my_membership uuid;
    v_is_target boolean := false;
    v_existing uuid;
    v_decision_id uuid;
    v_rules jsonb;
    v_default_method text;
    v_default_legitimacy text;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_s from public.group_sanctions where id=p_sanction_id for update;
    if v_s.id is null then raise exception 'sanction_not_found' using errcode='P0002'; end if;
    if v_s.status in ('reversed','completed','cancelled') then
        raise exception 'sanction_not_appealable: status=%', v_s.status using errcode='22023';
    end if;
    if not public.is_group_member(v_s.group_id) then
        raise exception 'not_a_member' using errcode='42501';
    end if;

    select id into v_my_membership from public.group_memberships
    where group_id=v_s.group_id and user_id=v_uid and status='active' limit 1;
    v_is_target := (v_my_membership is not null and v_my_membership = v_s.target_membership_id);

    if not v_is_target and not public.has_group_permission(v_s.group_id, 'sanctions.dispute') then
        raise exception 'missing_permission: sanctions.dispute' using errcode='42501';
    end if;

    if v_s.appeal_status = 'appealed' and v_s.appeal_decision_id is not null then
        select id into v_existing from public.group_decisions
        where id=v_s.appeal_decision_id and status='open';
        if v_existing is not null then return v_existing; end if;
        if v_s.appeal_status in ('upheld','reduced','overturned') then
            raise exception 'sanction_already_resolved: %', v_s.appeal_status using errcode='22023';
        end if;
    end if;

    select decision_rules into v_rules from public.groups where id=v_s.group_id;
    v_default_method := coalesce(v_rules->>'default_method','majority');
    v_default_legitimacy := coalesce(v_rules->>'default_legitimacy_source','majority');

    insert into public.group_decisions (
        group_id, title, body, decision_type, method, legitimacy_source,
        status, threshold_pct, quorum_pct, reference_kind, reference_id,
        metadata, opens_at, closes_at, created_by
    ) values (
        v_s.group_id, 'Apelación de sanción',
        coalesce(nullif(btrim(p_reason),''),'Sin razón'),
        'sanction_appeal', v_default_method, v_default_legitimacy,
        'open', 50.0, 1.0, 'sanction', p_sanction_id,
        jsonb_build_object('appeal_reason', p_reason,
            'appealed_by_membership_id', v_my_membership,
            'is_target', v_is_target, 'client_id', p_client_id),
        now(), now() + interval '7 days', v_uid
    ) returning id into v_decision_id;

    update public.group_sanctions
       set appealed_at=now(), appeal_decision_id=v_decision_id, appeal_status='appealed',
           status = case when status='active' then 'disputed' else status end,
           updated_at=now()
     where id=p_sanction_id;

    perform public.record_system_event(
        v_s.group_id, 'sanction.appealed', 'sanction', p_sanction_id,
        'Sanción apelada',
        jsonb_build_object('appeal_decision_id', v_decision_id,
            'appealed_by_membership_id', v_my_membership, 'reason', p_reason));

    return v_decision_id;
end$$;

grant execute on function public.start_sanction_appeal(uuid, text, text) to authenticated;
