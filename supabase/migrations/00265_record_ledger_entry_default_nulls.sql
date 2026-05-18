-- Mig 00229: add DEFAULT NULL to the optional uuid params of record_ledger_entry.
--
-- Symptom: any "expense" recorded via ResourceLedgerCoordinator 404s
-- (PostgREST returns 404 → Swift surfaces the generic "No pudimos
-- registrar el movimiento. Intenta de nuevo."). Two POST /rpc/
-- record_ledger_entry → 404 visible in api logs at 1778985727 /
-- 1778985726, immediately after a 200 from /rpc/resolve_governance.
--
-- Root cause
-- ==========
-- mig 00082 (and mig 00150's redefine) declared the signature as
--   p_group_id uuid, p_resource_id uuid, p_type text,
--   p_amount_cents bigint, p_from_member_id uuid, p_to_member_id uuid,
--   p_currency text DEFAULT 'MXN', p_metadata jsonb DEFAULT '{}'::jsonb
-- — `p_resource_id`, `p_from_member_id`, `p_to_member_id` had NO
-- default. The body already guards each with `if x is not null then ...`
-- so passing NULL is supported semantically; the missing default only
-- bites at PostgREST overload resolution time.
--
-- Swift's synthesized Codable conformance emits `encodeIfPresent`
-- for Optional<T>, so a `Params` struct with `p_to_member_id: nil`
-- OMITS the key entirely. PostgREST then looks for a function
-- accepting the remaining 7 keys → no match → 404.
--
-- The expense form in ResourceLedgerCoordinator submits with
-- toMemberId=nil (expense's counterparty is the implicit group pot
-- per the EntryKind doctrine), so it ALWAYS hit this 404.
--
-- Fix
-- ===
-- Add DEFAULT NULL to the three uuid params. Pure additive change —
-- existing callers passing all 8 keys still work; Swift callers that
-- omit the nil keys now resolve to the 5-param call form which PostgREST
-- supplies the defaults for.
--
-- The change is body-and-defaults only, not arg order / type / count,
-- so CREATE OR REPLACE is allowed (no DROP needed; doesn't break
-- existing GRANT or comment).
--
-- All server-side callers (fund_contribute / fund_record_expense / fine
-- atom emitters) already use named-arg `=>` syntax — they're unaffected
-- whether the param has a default or not.

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
