BEGIN;

CREATE OR REPLACE FUNCTION public.record_ledger_entry(
    p_group_id       uuid,
    p_resource_id    uuid    DEFAULT NULL,
    p_type           text    DEFAULT NULL,
    p_amount_cents   bigint  DEFAULT NULL,
    p_from_member_id uuid    DEFAULT NULL,
    p_to_member_id   uuid    DEFAULT NULL,
    p_currency       text    DEFAULT 'MXN',
    p_metadata       jsonb   DEFAULT '{}'::jsonb
)
RETURNS public.ledger_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    v_entry public.ledger_entries;
    v_allowed_types constant text[] := array[
        'expense', 'contribution', 'payout',
        'settlement', 'reimbursement',
        'fine_issued', 'fine_paid', 'fine_voided',
        'fine_officialized'
    ];
begin
    if auth.uid() is null then raise exception 'auth required'; end if;
    if not public.is_group_member(p_group_id, auth.uid()) then
        raise exception 'not a member of this group';
    end if;
    if p_amount_cents is null or p_amount_cents < 0 then
        raise exception 'amount must be non-negative';
    end if;
    if p_type is null or not (p_type = any (v_allowed_types)) then
        raise exception 'invalid ledger entry type: %', p_type;
    end if;
    if p_resource_id is not null then
        if not exists (
            select 1 from public.resources r
             where r.id = p_resource_id and r.group_id = p_group_id
        ) then
            raise exception 'resource does not belong to group';
        end if;
    end if;
    if p_from_member_id is not null then
        if not exists (
            select 1 from public.group_members gm
             where gm.id = p_from_member_id and gm.group_id = p_group_id and gm.active
        ) then
            raise exception 'from_member is not an active member of this group';
        end if;
    end if;
    if p_to_member_id is not null then
        if not exists (
            select 1 from public.group_members gm
             where gm.id = p_to_member_id and gm.group_id = p_group_id and gm.active
        ) then
            raise exception 'to_member is not an active member of this group';
        end if;
    end if;

    insert into public.ledger_entries (
        group_id, resource_id, type, amount_cents, currency,
        from_member_id, to_member_id, metadata,
        occurred_at, recorded_at, recorded_by
    )
    values (
        p_group_id, p_resource_id, p_type, p_amount_cents, coalesce(p_currency, 'MXN'),
        p_from_member_id, p_to_member_id, coalesce(p_metadata, '{}'::jsonb),
        now(), now(), auth.uid()
    )
    returning * into v_entry;

    return v_entry;
end;
$$;

COMMIT;
