-- d24_p12a_event_detail_summary_fix_counts
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- Hot-fix: event consolidado a resource_type='event' (D.24 P1). Comments/attachments
-- pueden venir con entity_kind='resource' o 'event' (allowlist permite ambos).
-- Contar ambos.
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
            where group_id=v_r.group_id
              and entity_id=p_event_id
              and entity_kind in ('event','resource')
              and status='active'
        ),
        'attachments_count', (
            select count(*) from public.group_attachments
            where group_id=v_r.group_id
              and entity_id=p_event_id
              and entity_kind in ('event','resource')
              and status='active'
        )
    );
end$$;
grant execute on function public.event_detail_summary(uuid) to authenticated;
