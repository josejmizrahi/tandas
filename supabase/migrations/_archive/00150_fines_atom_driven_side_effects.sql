-- 00150 — Constitution §14 Step 3c phase 1: atom-driven side effects
--
-- Context
-- =======
-- Step 3a (mig 00148) made fine_issued/fine_paid/fine_voided atoms emit.
-- Step 3b (mig 00149) created fines_view projection so readers derive
-- status from atoms instead of the stored column. This phase moves the
-- remaining side effects (user_action creation + system_event emission +
-- fineProposalReview resolution) from column-mutation triggers to
-- ledger_entries INSERT triggers, AND stops the RPCs from writing the
-- now-derived columns.
--
-- After this migration, fines.status / paid / waived / paid_at /
-- waived_at / waived_reason / paid_to_fund / appeal_vote_id are still
-- present as stored columns but become dead-write artifacts (RPCs no
-- longer write to them; readers use fines_view). 00151 drops them.
--
-- Atom-driven transition model
-- ============================
-- 1. fine_issued (already emits in 3a):  fine just created
-- 2. fine_officialized (NEW in 3c):       fine became binding obligation
--    - Auto-generated: emitted by finalize-fine-reviews edge function
--      when review_period.expires_at passes
--    - Manual:         emitted by issue_manual_fine (born officialized)
--                       or by officialize_fine RPC
-- 3. fine_paid (already emits in 3a):     obligation discharged
-- 4. fine_voided (already emits in 3a):   obligation annulled
--
-- Side effect mapping
-- ===================
-- OLD trigger fines_after_status_change ON status='officialized'
--   → user_action 'finePending' + system_event 'fineOfficialized'
-- NEW trigger on_fine_atom_inserted ON fine_officialized atom
--   → same user_action + system_event
--
-- OLD trigger fines_resolve_fine_pending ON paid/voided change
--   → resolve user_action 'finePending'
-- NEW trigger on_fine_atom_inserted ON fine_paid OR fine_voided atom
--   → same resolve
--
-- OLD trigger fines_resolve_proposal_review ON status='proposed' count=0
--   → resolve user_action 'fineProposalReview'
-- NEW trigger on_fine_atom_inserted ON any fine atom (officialized/paid/voided)
--   → re-check via fines_view, resolve if 0 proposed
--
-- All side effects skipped when atom has metadata.backfilled=true (so
-- the backfill below doesn't double-create user_actions).
--
-- Companion: Plans/Active/Constitution.md §14 Step 3c.

BEGIN;

-- ===========================================================================
-- Part 1 — Allow fine_officialized in record_ledger_entry
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.record_ledger_entry(
    p_group_id uuid,
    p_resource_id uuid,
    p_type text,
    p_amount_cents bigint,
    p_from_member_id uuid,
    p_to_member_id uuid,
    p_currency text DEFAULT 'MXN',
    p_metadata jsonb DEFAULT '{}'::jsonb
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
        'fine_officialized'  -- §14 Step 3c
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

-- ===========================================================================
-- Part 2 — Atom-driven side effects function + trigger
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.on_fine_atom_inserted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    v_fine        public.fines;
    v_fine_id     uuid;
    v_count_left  int;
begin
    -- Skip side effects on backfilled atoms (history reconstruction).
    if (NEW.metadata->>'backfilled')::boolean is true then
        return NEW;
    end if;

    -- Resolve fine reference. Atoms for fines always carry metadata.fine_id.
    v_fine_id := (NEW.metadata->>'fine_id')::uuid;
    if v_fine_id is null then return NEW; end if;

    select * into v_fine from public.fines where id = v_fine_id;
    if v_fine.id is null then return NEW; end if;

    case NEW.type
        when 'fine_officialized' then
            -- Replicates old on_fine_officialized trigger: create user_action
            -- finePending + emit system_event fineOfficialized.
            insert into public.user_actions (
                user_id, group_id, action_type, reference_id,
                title, body, priority
            )
            values (
                v_fine.user_id,
                v_fine.group_id,
                'finePending',
                v_fine.id,
                'Multa pendiente: $' || trim(to_char(v_fine.amount, 'FM999G999D00')),
                v_fine.reason,
                'high'
            );

            perform public.record_system_event(
                v_fine.group_id,
                'fineOfficialized',
                v_fine.id,
                null,
                jsonb_build_object(
                    'amount',  v_fine.amount,
                    'rule_id', v_fine.rule_id
                )
            );

        when 'fine_paid' then
            -- Replicates old fines_resolve_fine_pending side: resolve the
            -- finePending inbox row for this fine.
            update public.user_actions
               set resolved_at = now()
             where action_type  = 'finePending'
               and reference_id = v_fine.id
               and resolved_at  is null;

        when 'fine_voided' then
            update public.user_actions
               set resolved_at = now()
             where action_type  = 'finePending'
               and reference_id = v_fine.id
               and resolved_at  is null;

        else
            -- fine_issued is emitted on INSERT before any user_action exists;
            -- no inbox action to create/resolve. Just continue.
            null;
    end case;

    -- Replicates old fines_resolve_proposal_review trigger logic. For
    -- any fine atom that transitions a fine OUT of 'proposed' state
    -- (officialized/paid/voided), check if there are still proposed fines
    -- for the same event_id; if zero, resolve the host's
    -- fineProposalReview inbox row.
    if NEW.type in ('fine_officialized', 'fine_paid', 'fine_voided')
       and v_fine.event_id is not null then
        select count(*) into v_count_left
          from public.fines_view fv
         where fv.event_id = v_fine.event_id
           and fv.status   = 'proposed';
        if v_count_left = 0 then
            update public.user_actions
               set resolved_at = now()
             where action_type  = 'fineProposalReview'
               and reference_id = v_fine.event_id
               and resolved_at  is null;
        end if;
    end if;

    return NEW;
end;
$$;

DROP TRIGGER IF EXISTS on_fine_atom_inserted_trg ON public.ledger_entries;
CREATE TRIGGER on_fine_atom_inserted_trg
    AFTER INSERT ON public.ledger_entries
    FOR EACH ROW
    WHEN (NEW.type IN ('fine_issued', 'fine_officialized', 'fine_paid', 'fine_voided'))
    EXECUTE FUNCTION public.on_fine_atom_inserted();

COMMENT ON TRIGGER on_fine_atom_inserted_trg ON public.ledger_entries IS
    'Constitución §14 Step 3c: atom-driven side effects. Replaces the '
    'old fines_after_status_change + fines_resolve_fine_pending + '
    'fines_resolve_proposal_review triggers. Skips work on atoms whose '
    'metadata.backfilled=true so historical reconstruction does not '
    'double-emit user_actions.';

-- ===========================================================================
-- Part 3 — Backfill fine_officialized atoms for currently officialized fines
-- ===========================================================================
-- Includes:
--   - fines.status='officialized' (6 rows)
--   - fines.status='paid'         (already officialized first; 3 rows)
--   - fines.status='proposed' with auto_generated AND event_id review_period
--     past grace (the 4 stale rows the cron missed — see audit 2026-05-13)
--
-- All marked backfilled=true so the new trigger skips side effects.

INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
)
SELECT
    f.group_id,
    f.resource_id,
    'fine_officialized',
    (f.amount * 100)::bigint,
    'MXN',
    gm.id,
    NULL,
    jsonb_build_object(
        'fine_id',    f.id,
        'rule_id',    f.rule_id,
        'reason',     f.reason,
        'backfilled', true,
        'source',     CASE
            WHEN f.status IN ('officialized', 'paid', 'voided')
                THEN 'stored_column'
            ELSE 'review_period_expired'
        END
    ),
    COALESCE(
        (SELECT frp.officialized_at FROM public.fine_review_periods frp
          WHERE frp.event_id = f.event_id AND frp.officialized_at IS NOT NULL LIMIT 1),
        f.updated_at,
        f.created_at
    ),
    now(),
    NULL
FROM public.fines f
LEFT JOIN public.group_members gm
       ON gm.user_id = f.user_id
      AND gm.group_id = f.group_id
WHERE (
    f.status IN ('officialized', 'paid', 'voided', 'in_appeal')
    OR (
        f.status = 'proposed'
        AND f.auto_generated
        AND f.event_id IS NOT NULL
        AND EXISTS (
            SELECT 1 FROM public.fine_review_periods frp
             WHERE frp.event_id = f.event_id
               AND (frp.officialized_at IS NOT NULL OR frp.expires_at < now())
        )
    )
)
AND NOT EXISTS (
    SELECT 1 FROM public.ledger_entries le
     WHERE le.type = 'fine_officialized'
       AND (le.metadata->>'fine_id')::uuid = f.id
);

-- ===========================================================================
-- Part 4 — Update fines_view to derive officialized from atom
-- ===========================================================================
-- Also drops paid_to_fund + appeal_vote_id from the view since 00151 will
-- drop those underlying columns. Swift Fine struct doesn't decode them so
-- this is safe.

DROP VIEW IF EXISTS public.fines_view;

CREATE VIEW public.fines_view
WITH (security_invoker = true)
AS
SELECT
    f.id,
    f.group_id,
    f.user_id,
    f.rule_id,
    f.event_id,
    f.resource_id,
    f.reason,
    f.amount,
    -- Derived status: pure atom + open vote derivation. No more fallback
    -- to stored f.status — every officialized fine has a fine_officialized
    -- atom (live RPC writes one; backfill above covered history).
    CASE
        WHEN EXISTS (
            SELECT 1 FROM public.ledger_entries le
             WHERE le.type = 'fine_voided'
               AND (le.metadata->>'fine_id')::uuid = f.id
        ) THEN 'voided'
        WHEN EXISTS (
            SELECT 1 FROM public.ledger_entries le
             WHERE le.type = 'fine_paid'
               AND (le.metadata->>'fine_id')::uuid = f.id
        ) THEN 'paid'
        WHEN EXISTS (
            SELECT 1 FROM public.votes v
             WHERE v.vote_type = 'fine_appeal'
               AND v.reference_id = f.id
               AND v.status = 'open'
        ) THEN 'in_appeal'
        WHEN EXISTS (
            SELECT 1 FROM public.ledger_entries le
             WHERE le.type = 'fine_officialized'
               AND (le.metadata->>'fine_id')::uuid = f.id
        ) THEN 'officialized'
        ELSE 'proposed'
    END AS status,
    EXISTS (
        SELECT 1 FROM public.ledger_entries le
         WHERE le.type = 'fine_paid'
           AND (le.metadata->>'fine_id')::uuid = f.id
    ) AS paid,
    (
        SELECT le.occurred_at
          FROM public.ledger_entries le
         WHERE le.type = 'fine_paid'
           AND (le.metadata->>'fine_id')::uuid = f.id
         ORDER BY le.occurred_at DESC
         LIMIT 1
    ) AS paid_at,
    EXISTS (
        SELECT 1 FROM public.ledger_entries le
         WHERE le.type = 'fine_voided'
           AND (le.metadata->>'fine_id')::uuid = f.id
    ) AS waived,
    (
        SELECT le.occurred_at
          FROM public.ledger_entries le
         WHERE le.type = 'fine_voided'
           AND (le.metadata->>'fine_id')::uuid = f.id
         ORDER BY le.occurred_at DESC
         LIMIT 1
    ) AS waived_at,
    (
        SELECT le.metadata->>'reason'
          FROM public.ledger_entries le
         WHERE le.type = 'fine_voided'
           AND (le.metadata->>'fine_id')::uuid = f.id
         ORDER BY le.occurred_at DESC
         LIMIT 1
    ) AS waived_reason,
    f.auto_generated,
    f.issued_by,
    f.details,
    f.created_at,
    f.updated_at,
    f.rule_snapshot
FROM public.fines f;

COMMENT ON VIEW public.fines_view IS
    'Constitución §14 Step 3c: projection over fines + ledger atoms + '
    'votes. Five status values fully derived: voided > paid > in_appeal '
    '> officialized > proposed. paid_to_fund + appeal_vote_id columns '
    'dropped — never read by Swift Fine struct; legacy artifacts.';

-- ===========================================================================
-- Part 5 — Refactor RPCs to stop writing derived columns + emit atoms
-- ===========================================================================

-- 5a: officialize_fine — emit fine_officialized atom; stop UPDATE fines.status
CREATE OR REPLACE FUNCTION public.officialize_fine(p_fine_id uuid)
RETURNS public.fines
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    f           public.fines;
    uid         uuid := auth.uid();
    v_member_id uuid;
    v_has_atom  boolean;
begin
    if uid is null then raise exception 'not authenticated'; end if;

    select * into f from public.fines where id = p_fine_id for update;
    if f.id is null then raise exception 'fine not found'; end if;

    -- Idempotency: if already officialized via atom, return early.
    select exists (
        select 1 from public.ledger_entries le
         where le.type = 'fine_officialized'
           and (le.metadata->>'fine_id')::uuid = f.id
    ) into v_has_atom;

    if v_has_atom then
        return f;
    end if;

    if not (
        public.is_group_admin(f.group_id, uid)
        or exists (select 1 from public.events e where e.id = f.event_id and e.host_id = uid)
    ) then
        raise exception 'only host or admin can officialize this fine';
    end if;

    -- Mark the review_period (kept for ops/audit; projection no longer
    -- depends on it but the cron and inspection tooling do).
    update public.fine_review_periods
       set officialized_at = now(),
           officialized_by = (select id from public.group_members
                               where user_id = uid and group_id = f.group_id limit 1)
     where event_id = f.event_id and officialized_at is null;

    -- Emit the atom. The on_fine_atom_inserted trigger handles
    -- user_action + system_event side effects.
    select id into v_member_id
      from public.group_members
     where group_id = f.group_id and user_id = f.user_id
     limit 1;

    insert into public.ledger_entries (
        group_id, resource_id, type, amount_cents, currency,
        from_member_id, to_member_id, metadata,
        occurred_at, recorded_at, recorded_by
    )
    values (
        f.group_id,
        f.resource_id,
        'fine_officialized',
        (f.amount * 100)::bigint,
        'MXN',
        v_member_id,
        null,
        jsonb_build_object(
            'fine_id', f.id,
            'rule_id', f.rule_id,
            'via',     'officialize_fine_rpc'
        ),
        now(),
        now(),
        uid
    );

    return f;
end;
$$;

-- 5b: pay_fine — SELECT FOR UPDATE + atom idempotency + emit atom +
-- bump fund_balance (kept here for now; could move to atom trigger later).
-- Stops writing fines.paid / paid_at / paid_to_fund.
CREATE OR REPLACE FUNCTION public.pay_fine(p_fine_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    f            public.fines;
    g            public.groups;
    v_member_id  uuid;
    v_has_atom   boolean;
begin
    select * into f from public.fines where id = p_fine_id for update;
    if not found then raise exception 'fine not found'; end if;

    select * into g from public.groups where id = f.group_id;

    if not (f.user_id = auth.uid() or public.is_group_admin(f.group_id, auth.uid())) then
        raise exception 'not allowed';
    end if;

    -- Atom-based idempotency (replaces the old `if f.paid then return`).
    select exists (
        select 1 from public.ledger_entries le
         where le.type = 'fine_paid'
           and (le.metadata->>'fine_id')::uuid = f.id
    ) into v_has_atom;

    if v_has_atom then
        return;
    end if;

    -- Emit fine_paid atom. on_fine_atom_inserted trigger handles user_action
    -- resolution.
    select id into v_member_id
      from public.group_members
     where group_id = f.group_id and user_id = f.user_id
     limit 1;

    insert into public.ledger_entries (
        group_id, resource_id, type, amount_cents, currency,
        from_member_id, to_member_id, metadata,
        occurred_at, recorded_at, recorded_by
    )
    values (
        f.group_id,
        f.resource_id,
        'fine_paid',
        (f.amount * 100)::bigint,
        'MXN',
        v_member_id,
        null,
        jsonb_build_object(
            'fine_id',      f.id,
            'paid_to_fund', g.fund_enabled
        ),
        now(),
        now(),
        auth.uid()
    );

    -- Bump the group's fund balance if applicable. Kept in pay_fine for
    -- simplicity; could move to an atom-driven trigger in 3c.2 if desired.
    if g.fund_enabled then
        update public.groups
           set fund_balance = fund_balance + f.amount
         where id = g.id;
    end if;
end;
$$;

-- 5c: void_fine — SELECT FOR UPDATE + atom idempotency + emit atom.
-- Stops writing fines.status / waived / waived_at / waived_reason and
-- the now-redundant explicit user_action insert + system_event emission
-- (the atom trigger handles those).
CREATE OR REPLACE FUNCTION public.void_fine(
    p_fine_id uuid,
    p_reason text DEFAULT NULL
)
RETURNS public.fines
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    f           public.fines;
    uid         uuid := auth.uid();
    v_member_id uuid;
    v_has_atom  boolean;
    v_status    text;
begin
    if uid is null then raise exception 'not authenticated'; end if;

    select * into f from public.fines where id = p_fine_id for update;
    if f.id is null then raise exception 'fine not found'; end if;
    if not public.is_group_admin(f.group_id, uid) then
        raise exception 'only admins can void fines';
    end if;
    if length(coalesce(p_reason, '')) < 2 then
        raise exception 'reason required';
    end if;

    -- Derive current status from projection — the column may be stale.
    select fv.status into v_status from public.fines_view fv where fv.id = p_fine_id;
    if v_status not in ('proposed', 'officialized') then
        raise exception 'cannot void fine with status %', v_status;
    end if;

    -- Atom-based idempotency.
    select exists (
        select 1 from public.ledger_entries le
         where le.type = 'fine_voided'
           and (le.metadata->>'fine_id')::uuid = f.id
    ) into v_has_atom;

    if v_has_atom then
        return f;
    end if;

    -- Emit fine_voided atom. on_fine_atom_inserted trigger handles
    -- user_action 'finePending' resolution. We still emit the explicit
    -- 'fineVoided' user_action + system_event since the recipient (the
    -- fined user) needs a different message than just "your finePending
    -- got resolved".
    select id into v_member_id
      from public.group_members
     where group_id = f.group_id and user_id = f.user_id
     limit 1;

    insert into public.ledger_entries (
        group_id, resource_id, type, amount_cents, currency,
        from_member_id, to_member_id, metadata,
        occurred_at, recorded_at, recorded_by
    )
    values (
        f.group_id,
        f.resource_id,
        'fine_voided',
        (f.amount * 100)::bigint,
        'MXN',
        v_member_id,
        null,
        jsonb_build_object(
            'fine_id',          f.id,
            'reason',           p_reason,
            'via',              'admin',
            'voided_by_user_id', uid
        ),
        now(),
        now(),
        uid
    );

    insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
    ) values (
        f.user_id, f.group_id, 'fineVoided', f.id,
        'Multa anulada por admin: $' || trim(to_char(f.amount, 'FM999G999D00')),
        p_reason,
        'low'
    );

    perform public.record_system_event(
        f.group_id,
        'fineVoided',
        f.id,
        null,
        jsonb_build_object(
            'amount',           f.amount,
            'reason',           p_reason,
            'voided_by_user_id', uid
        )
    );

    return f;
end;
$$;

-- 5d: start_fine_appeal — stops writing fines.status='in_appeal'. The
-- in_appeal state is derived in fines_view from the open vote existence.
CREATE OR REPLACE FUNCTION public.start_fine_appeal(p_fine_id uuid, p_reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    v_caller_uid uuid := auth.uid();
    v_fine       public.fines%rowtype;
    v_member_id  uuid;
    v_vote_id    uuid;
    v_title      text;
    v_status     text;
begin
    if v_caller_uid is null then
        raise exception 'not authenticated' using errcode = '42501';
    end if;
    if length(coalesce(p_reason, '')) < 2 then
        raise exception 'reason required' using errcode = '22023';
    end if;

    select * into v_fine from public.fines where id = p_fine_id;
    if not found then
        raise exception 'fine not found' using errcode = '02000';
    end if;

    if v_fine.user_id <> v_caller_uid then
        raise exception 'only the fined user can file an appeal' using errcode = '42501';
    end if;

    -- Validate via projection (status is derived).
    select fv.status into v_status from public.fines_view fv where fv.id = p_fine_id;
    if v_status not in ('officialized', 'in_appeal') then
        raise exception 'cannot appeal a fine in status %', v_status using errcode = '22023';
    end if;

    select id into v_member_id
      from public.group_members
     where group_id = v_fine.group_id
       and user_id  = v_caller_uid
       and active   = true;

    if v_member_id is null then
        raise exception 'caller is not an active member of the group' using errcode = '42501';
    end if;

    v_title := 'Apelación · $' || trim(to_char(v_fine.amount, 'FM999G999D00'));

    -- Open the vote. Once it's open, the projection derives
    -- status='in_appeal' for this fine — no column write needed.
    v_vote_id := public.start_vote(
        p_group_id     => v_fine.group_id,
        p_vote_type    => 'fine_appeal',
        p_reference_id => p_fine_id,
        p_title        => v_title,
        p_description  => p_reason,
        p_payload      => jsonb_build_object('member_id', v_member_id, 'reason', p_reason)
    );

    perform public.record_system_event(
        v_fine.group_id,
        'appealCreated',
        p_fine_id,
        v_member_id,
        jsonb_build_object(
            'vote_id', v_vote_id,
            'amount',  v_fine.amount,
            'reason',  p_reason
        )
    );

    return v_vote_id;
end;
$$;

-- 5e: finalize_vote (fine_appeal branch) — stops writing fines.status /
-- waived / waived_at / waived_reason. Status derives from atoms + open
-- vote existence (vote becomes non-open here → in_appeal projection ends).
CREATE OR REPLACE FUNCTION public.finalize_vote(p_vote_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    v_vote                public.votes%rowtype;
    v_in_favor            int;
    v_against             int;
    v_abstained           int;
    v_pending             int;
    v_total               int;
    v_voted               int;
    v_quorum_count        int;
    v_resolution          text;
    v_founder_user_id     uuid;
    v_founder_member_id   uuid;
    v_rule_id             uuid;
    v_rule_name           text;
    v_current_amount      int;
    v_proposed_amount     int;
    v_fine                public.fines;
    v_fine_member_id      uuid;
begin
    select * into v_vote from public.votes where id = p_vote_id for update;
    if not found then raise exception 'vote not found' using errcode = '02000'; end if;
    if v_vote.status <> 'open' then
        return coalesce(v_vote.payload->>'resolution', 'unknown');
    end if;

    select
        count(*) filter (where choice = 'in_favor'),
        count(*) filter (where choice = 'against'),
        count(*) filter (where choice = 'abstained'),
        count(*) filter (where choice = 'pending'),
        count(*)
    into v_in_favor, v_against, v_abstained, v_pending, v_total
    from public.vote_casts
    where vote_id = p_vote_id;

    v_voted := v_in_favor + v_against + v_abstained;
    v_quorum_count := greatest(
        ceil(v_total::numeric * v_vote.quorum_percent / 100)::int,
        v_vote.quorum_min_absolute
    );

    if v_voted < v_quorum_count then
        v_resolution := 'quorum_failed';
    elsif v_in_favor::numeric * 100 >= (v_in_favor + v_against)::numeric * v_vote.threshold_percent then
        v_resolution := 'passed';
    else
        v_resolution := 'failed';
    end if;

    update public.votes
    set status = case when v_resolution = 'quorum_failed' then 'quorum_failed' else 'resolved' end,
        resolved_at = now(),
        counts = jsonb_build_object(
            'inFavor', v_in_favor, 'against', v_against, 'abstained', v_abstained,
            'pending', v_pending, 'totalEligible', v_total,
            'quorumRequired', v_quorum_count, 'resolution', v_resolution
        ),
        payload = payload || jsonb_build_object('resolution', v_resolution)
    where id = p_vote_id;

    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (
        v_vote.group_id, 'voteResolved', p_vote_id, null,
        jsonb_build_object('vote_type', v_vote.vote_type, 'reference_id', v_vote.reference_id, 'resolution', v_resolution)
    );

    insert into public.notifications_outbox (
        group_id, recipient_member_id, notification_type, payload, deep_link
    )
    select
        v_vote.group_id, vc.member_id, 'voteResolved',
        jsonb_build_object(
            'vote_id', p_vote_id, 'vote_type', v_vote.vote_type,
            'reference_id', v_vote.reference_id, 'resolution', v_resolution, 'title', v_vote.title
        ),
        'ruul://vote/' || p_vote_id::text
    from public.vote_casts vc
    where vc.vote_id = p_vote_id;

    if v_vote.vote_type = 'fine_appeal' then
        insert into public.notifications_outbox (
            group_id, recipient_member_id, notification_type, payload, deep_link
        )
        select
            v_vote.group_id, (v_vote.payload->>'member_id')::uuid, 'voteResolved',
            jsonb_build_object(
                'vote_id', p_vote_id, 'vote_type', v_vote.vote_type,
                'reference_id', v_vote.reference_id, 'resolution', v_resolution,
                'title', v_vote.title, 'is_appellant', true
            ),
            'ruul://vote/' || p_vote_id::text
        where v_vote.payload ? 'member_id'
          and (v_vote.payload->>'member_id') <> '';
    end if;

    if v_vote.vote_type = 'rule_change' and v_resolution = 'passed' then
        v_current_amount := nullif(v_vote.payload->>'current_amount', '')::int;
        v_proposed_amount := nullif(v_vote.payload->>'proposed_amount', '')::int;
        if v_current_amount is null or v_proposed_amount is null then return v_resolution; end if;

        select gm.id, gm.user_id into v_founder_member_id, v_founder_user_id
        from public.group_members gm
        where gm.group_id = v_vote.group_id and gm.roles ?| array['founder'] and gm.active = true
        order by gm.created_at asc
        limit 1;

        if v_founder_user_id is not null then
            v_rule_id := v_vote.reference_id;
            select coalesce(name, title, 'Regla #' || left(v_rule_id::text, 8))
              into v_rule_name
              from public.rules where id = v_rule_id;
            v_rule_name := coalesce(v_rule_name, 'Regla #' || left(v_rule_id::text, 8));

            insert into public.user_actions (
                user_id, group_id, action_type, reference_id, title, body, priority
            )
            select
                v_founder_user_id, v_vote.group_id, 'ruleChangeApplyPending', p_vote_id,
                'Aplicar cambio aprobado: ' || v_rule_name,
                format('Votado: $%s → $%s', v_current_amount, v_proposed_amount), 'high'
            where not exists (
                select 1 from public.user_actions
                 where reference_id = p_vote_id and action_type = 'ruleChangeApplyPending'
            );

            insert into public.notifications_outbox (
                group_id, recipient_member_id, notification_type, payload, deep_link
            )
            values (
                v_vote.group_id, v_founder_member_id, 'ruleChangeApplyPending',
                jsonb_build_object(
                    'vote_id', p_vote_id, 'rule_id', v_rule_id, 'rule_name', v_rule_name,
                    'current_amount', v_current_amount, 'proposed_amount', v_proposed_amount,
                    'title', 'Aplicar cambio aprobado',
                    'body', format('Votado: $%s → $%s', v_current_amount, v_proposed_amount)
                ),
                'ruul://rule/' || v_rule_id::text || '/edit?proposedAmount=' || v_proposed_amount::text
            );
        end if;
    end if;

    -- fine_appeal resolution: emit fine_voided atom on 'passed'. No column
    -- writes — projection handles everything (in_appeal disappears because
    -- vote is no longer open; status becomes 'voided' if atom emitted else
    -- 'officialized' (assuming fine_officialized atom from earlier).
    if v_vote.vote_type = 'fine_appeal' and v_vote.reference_id is not null then
        select * into v_fine from public.fines where id = v_vote.reference_id;

        if v_fine.id is not null then
            insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
            values (
                v_vote.group_id,
                'appealResolved',
                v_vote.reference_id,
                nullif(v_vote.payload->>'member_id', '')::uuid,
                jsonb_build_object(
                    'vote_id',         p_vote_id,
                    'fine_id',         v_vote.reference_id,
                    'resolution',      v_resolution,
                    'new_fine_status', case when v_resolution = 'passed' then 'voided' else 'officialized' end,
                    'amount',          v_fine.amount
                )
            );

            update public.user_actions
               set resolved_at = now()
             where reference_id = p_vote_id
               and action_type  = 'appealVotePending'
               and resolved_at  is null;

            if v_resolution = 'passed' then
                select id into v_fine_member_id
                  from public.group_members
                 where group_id = v_fine.group_id and user_id = v_fine.user_id
                 limit 1;

                insert into public.ledger_entries (
                    group_id, resource_id, type, amount_cents, currency,
                    from_member_id, to_member_id, metadata,
                    occurred_at, recorded_at, recorded_by
                )
                values (
                    v_fine.group_id,
                    v_fine.resource_id,
                    'fine_voided',
                    (v_fine.amount * 100)::bigint,
                    'MXN',
                    v_fine_member_id,
                    null,
                    jsonb_build_object(
                        'fine_id', v_vote.reference_id,
                        'via',     'appeal',
                        'vote_id', p_vote_id,
                        'reason',  'appeal_passed (vote ' || left(p_vote_id::text, 8) || ')'
                    ),
                    now(),
                    now(),
                    null
                );
            end if;
        end if;
    end if;

    return v_resolution;
end;
$$;

-- 5f: issue_manual_fine — manual fines are born officialized. After the
-- INSERT, also emit fine_officialized atom (in addition to fine_issued
-- which the fines_emit_fine_issued_atom trigger handles).
CREATE OR REPLACE FUNCTION public.issue_manual_fine(
    p_group_id uuid,
    p_user_id uuid,
    p_amount numeric,
    p_reason text,
    p_rule_id uuid,
    p_event_id uuid,
    p_resource_id uuid DEFAULT NULL
)
RETURNS public.fines
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    f             public.fines;
    r             public.rules;
    v_snapshot    jsonb;
    v_resource_id uuid;
    v_member_id   uuid;
begin
    if auth.uid() is null then raise exception 'auth required'; end if;
    if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
    if not public.is_group_member(p_group_id, p_user_id) then raise exception 'target user not a member'; end if;
    if p_amount < 0 then raise exception 'amount must be non-negative'; end if;
    if length(coalesce(p_reason, '')) < 2 then raise exception 'reason required'; end if;

    if p_rule_id is not null then
        select * into r from public.rules where id = p_rule_id;
        if found then
            v_snapshot := jsonb_build_object(
                'trigger',    coalesce(r.trigger, to_jsonb(r.conditions)),
                'action',     coalesce(r.action,  to_jsonb(r.consequences)),
                'rule_title', coalesce(r.title,   r.name),
                'rule_slug',  r.slug
            );
        end if;
    end if;

    v_resource_id := coalesce(p_resource_id, p_event_id);

    -- Stored status defaults to 'proposed' (per the column default). We
    -- intentionally do NOT write 'officialized' here — that would fire the
    -- legacy fines_after_status_change trigger AND the new on_fine_atom
    -- trigger when we emit the atom below, double-creating user_actions.
    -- The projection reads from the atom; column will be dropped in 00151.
    insert into public.fines (
        group_id, user_id, amount, reason, rule_id, event_id, resource_id,
        auto_generated, issued_by, rule_snapshot
    )
    values (
        p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_event_id, v_resource_id,
        false, auth.uid(), v_snapshot
    )
    returning * into f;

    -- Emit fine_officialized atom so the projection + new side-effect
    -- trigger create the finePending user_action + fineOfficialized event.
    -- fine_issued atom comes from fines_emit_fine_issued_atom trigger.
    select id into v_member_id
      from public.group_members
     where group_id = f.group_id and user_id = f.user_id
     limit 1;

    insert into public.ledger_entries (
        group_id, resource_id, type, amount_cents, currency,
        from_member_id, to_member_id, metadata,
        occurred_at, recorded_at, recorded_by
    )
    values (
        f.group_id, f.resource_id, 'fine_officialized', (f.amount * 100)::bigint, 'MXN',
        v_member_id, null,
        jsonb_build_object(
            'fine_id', f.id,
            'rule_id', f.rule_id,
            'via',     'issue_manual_fine'
        ),
        now(), now(), auth.uid()
    );

    return f;
end;
$$;

COMMIT;
