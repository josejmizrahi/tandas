-- 00148 — Constitution §14 Step 3a: emit fine atoms (foundation for 3b projection)
--
-- Context
-- =======
-- Constitución §14 Step 3 declares "fines_view derivada de ledger_entries +
-- votes + review_periods" — but the audit (2026-05-13) revealed that:
--
--   - ledger_entries has ZERO fine_paid / fine_voided / fine_issued rows
--   - pay_fine writes fines.paid=true but emits no atom
--   - void_fine writes fines.status='voided' but emits no atom
--   - finalize_vote (fine_appeal branch) mutates fines.status='voided' but
--     emits no atom
--
-- The view derivation in 3b is impossible until atoms exist. This migration
-- is the foundation: it makes atom emission part of every path that
-- transitions a fine's monetary state, plus backfills history.
--
-- Atomic semantics
-- ================
-- All three atom types use:
--   from_member_id = fined user's group_members.id (the obligation holder)
--   to_member_id   = NULL (group is the implicit counterparty)
--   amount_cents   = fines.amount × 100 (numeric → bigint cents)
--   metadata       = {fine_id, plus type-specific fields}
--
-- fine_issued: emitted on every fine creation (via trigger so manual + auto
--              + future paths all covered).
-- fine_paid:   emitted by pay_fine RPC after the fines row is updated.
-- fine_voided: emitted by void_fine RPC and by finalize_vote(fine_appeal)
--              when resolution = 'passed'.
--
-- Net obligation per member = Σ fine_issued − Σ fine_paid − Σ fine_voided.
-- Projection in 3b reads exactly this.
--
-- Backfill (this migration)
-- =========================
-- 19 fines exist; 3 are paid; 0 voided. So we backfill 19 fine_issued atoms
-- + 3 fine_paid atoms. All backfill INSERTs are idempotent via NOT EXISTS
-- on metadata.fine_id, so re-running the migration is safe.
--
-- What this migration does NOT do
-- ================================
-- - Does NOT touch fines.status, fines.paid, fines.waived columns.
-- - Does NOT create fines_view (that is Step 3b).
-- - Does NOT drop any triggers or columns (that is Step 3c).
-- - Does NOT change the behavior of any RPC for callers — atom emission is
--   strictly additive.
--
-- Reversibility
-- =============
-- DELETE FROM ledger_entries WHERE type IN ('fine_paid','fine_voided','fine_issued');
-- would fail because of the atom_no_mutation_guard. Reverting requires
-- temporarily disabling the guard, deleting, restoring the guard, and
-- restoring the old function bodies from mig 00146 (pay_fine), mig 00028
-- (void_fine), mig 00123 (finalize_vote v4).
--
-- Companion: Plans/Active/Constitution.md §14.

BEGIN;

-- ===========================================================================
-- Part 1 — Expand record_ledger_entry to accept 'fine_voided'
-- ('fine_issued' and 'fine_paid' were already in the allowed list)
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
        'fine_issued', 'fine_paid', 'fine_voided'  -- §14 Step 3a
    ];
begin
    if auth.uid() is null then
        raise exception 'auth required';
    end if;

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
-- Part 2 — Backfill historical atoms (BEFORE installing triggers/RPC writes)
-- ===========================================================================

-- 2a: fine_issued atom for every existing fine (19 rows expected)
INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
)
SELECT
    f.group_id,
    f.resource_id,
    'fine_issued',
    (f.amount * 100)::bigint,
    'MXN',
    gm.id,
    NULL,
    jsonb_build_object(
        'fine_id',        f.id,
        'rule_id',        f.rule_id,
        'reason',         f.reason,
        'auto_generated', f.auto_generated,
        'backfilled',     true
    ),
    f.created_at,
    now(),
    f.issued_by
FROM public.fines f
LEFT JOIN public.group_members gm
       ON gm.user_id = f.user_id
      AND gm.group_id = f.group_id
WHERE NOT EXISTS (
    SELECT 1 FROM public.ledger_entries le
     WHERE le.type = 'fine_issued'
       AND (le.metadata->>'fine_id')::uuid = f.id
);

-- 2b: fine_paid atom for paid fines (3 rows expected)
INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
)
SELECT
    f.group_id,
    f.resource_id,
    'fine_paid',
    (f.amount * 100)::bigint,
    'MXN',
    gm.id,
    NULL,
    jsonb_build_object(
        'fine_id',     f.id,
        'paid_to_fund', f.paid_to_fund,
        'backfilled',  true
    ),
    COALESCE(f.paid_at, f.updated_at, f.created_at),
    now(),
    NULL
FROM public.fines f
LEFT JOIN public.group_members gm
       ON gm.user_id = f.user_id
      AND gm.group_id = f.group_id
WHERE f.paid = true
  AND NOT EXISTS (
    SELECT 1 FROM public.ledger_entries le
     WHERE le.type = 'fine_paid'
       AND (le.metadata->>'fine_id')::uuid = f.id
  );

-- 2c: fine_voided atom for voided fines (0 rows expected today but idempotent)
INSERT INTO public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
)
SELECT
    f.group_id,
    f.resource_id,
    'fine_voided',
    (f.amount * 100)::bigint,
    'MXN',
    gm.id,
    NULL,
    jsonb_build_object(
        'fine_id',       f.id,
        'reason',        f.waived_reason,
        'via',           CASE WHEN f.appeal_vote_id IS NOT NULL THEN 'appeal' ELSE 'admin' END,
        'appeal_vote_id', f.appeal_vote_id,
        'backfilled',    true
    ),
    COALESCE(f.waived_at, f.updated_at, f.created_at),
    now(),
    NULL
FROM public.fines f
LEFT JOIN public.group_members gm
       ON gm.user_id = f.user_id
      AND gm.group_id = f.group_id
WHERE f.status = 'voided'
  AND NOT EXISTS (
    SELECT 1 FROM public.ledger_entries le
     WHERE le.type = 'fine_voided'
       AND (le.metadata->>'fine_id')::uuid = f.id
  );

-- ===========================================================================
-- Part 3 — Trigger: emit fine_issued atom on every fines INSERT
-- (catches manual + auto-generated + any future creation paths)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.emit_fine_issued_atom()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    v_member_id uuid;
begin
    -- Translate fines.user_id (auth.users.id) → group_members.id.
    -- Active filter intentionally omitted: a fine issued to a member who
    -- has since left should still record the atom.
    SELECT id INTO v_member_id
    FROM public.group_members
    WHERE group_id = NEW.group_id AND user_id = NEW.user_id
    LIMIT 1;

    INSERT INTO public.ledger_entries (
        group_id, resource_id, type, amount_cents, currency,
        from_member_id, to_member_id, metadata,
        occurred_at, recorded_at, recorded_by
    )
    VALUES (
        NEW.group_id,
        NEW.resource_id,
        'fine_issued',
        (NEW.amount * 100)::bigint,
        'MXN',
        v_member_id,
        NULL,
        jsonb_build_object(
            'fine_id',        NEW.id,
            'rule_id',        NEW.rule_id,
            'reason',         NEW.reason,
            'auto_generated', NEW.auto_generated
        ),
        NEW.created_at,
        now(),
        NEW.issued_by
    );

    RETURN NEW;
end;
$$;

DROP TRIGGER IF EXISTS fines_emit_fine_issued_atom ON public.fines;
CREATE TRIGGER fines_emit_fine_issued_atom
    AFTER INSERT ON public.fines
    FOR EACH ROW
    EXECUTE FUNCTION public.emit_fine_issued_atom();

COMMENT ON TRIGGER fines_emit_fine_issued_atom ON public.fines IS
    'Constitución §14 Step 3a: emits ledger_entry type=fine_issued atom on '
    'every fine creation. Foundation for fines_view projection (3b). '
    'Will likely be retired in 3c when fines table is restructured.';

-- ===========================================================================
-- Part 4 — Refactor pay_fine to emit fine_paid atom (additively)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.pay_fine(p_fine_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
declare
    f public.fines;
    g public.groups;
    v_member_id uuid;
    v_updated int;
begin
    select * into f
      from public.fines
     where id = p_fine_id
     for update;

    if not found then
        raise exception 'fine not found';
    end if;

    select * into g from public.groups where id = f.group_id;

    if not (f.user_id = auth.uid() or public.is_group_admin(f.group_id, auth.uid())) then
        raise exception 'not allowed';
    end if;

    if f.paid then return; end if;

    update public.fines
       set paid          = true,
           paid_at       = now(),
           paid_to_fund  = g.fund_enabled
     where id   = p_fine_id
       and paid = false;

    get diagnostics v_updated = row_count;
    if v_updated = 0 then
        return;
    end if;

    if g.fund_enabled then
        update public.groups
           set fund_balance = fund_balance + f.amount
         where id = g.id;
    end if;

    -- §14 Step 3a: emit fine_paid atom (foundation for 3b projection).
    SELECT id INTO v_member_id
    FROM public.group_members
    WHERE group_id = f.group_id AND user_id = f.user_id
    LIMIT 1;

    INSERT INTO public.ledger_entries (
        group_id, resource_id, type, amount_cents, currency,
        from_member_id, to_member_id, metadata,
        occurred_at, recorded_at, recorded_by
    )
    VALUES (
        f.group_id,
        f.resource_id,
        'fine_paid',
        (f.amount * 100)::bigint,
        'MXN',
        v_member_id,
        NULL,
        jsonb_build_object(
            'fine_id',      f.id,
            'paid_to_fund', g.fund_enabled
        ),
        now(),
        now(),
        auth.uid()
    );
end;
$$;

-- ===========================================================================
-- Part 5 — Refactor void_fine to emit fine_voided atom (additively)
-- ===========================================================================

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
    f public.fines;
    uid uuid := auth.uid();
    v_member_id uuid;
begin
    if uid is null then raise exception 'not authenticated'; end if;
    select * into f from public.fines where id = p_fine_id;
    if f.id is null then raise exception 'fine not found'; end if;
    if not public.is_group_admin(f.group_id, uid) then
        raise exception 'only admins can void fines';
    end if;
    if f.status not in ('proposed','officialized') then
        raise exception 'cannot void fine with status %', f.status;
    end if;
    if length(coalesce(p_reason, '')) < 2 then
        raise exception 'reason required';
    end if;

    update public.fines
       set status        = 'voided',
           waived        = true,
           waived_at     = now(),
           waived_reason = p_reason
     where id = p_fine_id
    returning * into f;

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

    -- §14 Step 3a: emit fine_voided atom (foundation for 3b projection).
    SELECT id INTO v_member_id
    FROM public.group_members
    WHERE group_id = f.group_id AND user_id = f.user_id
    LIMIT 1;

    INSERT INTO public.ledger_entries (
        group_id, resource_id, type, amount_cents, currency,
        from_member_id, to_member_id, metadata,
        occurred_at, recorded_at, recorded_by
    )
    VALUES (
        f.group_id,
        f.resource_id,
        'fine_voided',
        (f.amount * 100)::bigint,
        'MXN',
        v_member_id,
        NULL,
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

    return f;
end;
$$;

-- ===========================================================================
-- Part 6 — Refactor finalize_vote (fine_appeal passed → fine_voided atom)
-- ===========================================================================

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
    v_new_fine_status     text;
    v_fine_amount         int;
    v_fine_group_id       uuid;
    v_fine_user_id        uuid;
    v_fine_resource_id    uuid;
    v_fine_member_id      uuid;
    v_fine_updated        int;
begin
    select * into v_vote from public.votes where id = p_vote_id for update;
    if not found then
        raise exception 'vote not found' using errcode = '02000';
    end if;
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

    v_voted        := v_in_favor + v_against + v_abstained;
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
    set status      = case when v_resolution = 'quorum_failed' then 'quorum_failed' else 'resolved' end,
        resolved_at = now(),
        counts      = jsonb_build_object(
            'inFavor',        v_in_favor,
            'against',        v_against,
            'abstained',      v_abstained,
            'pending',        v_pending,
            'totalEligible',  v_total,
            'quorumRequired', v_quorum_count,
            'resolution',     v_resolution
        ),
        payload = payload || jsonb_build_object('resolution', v_resolution)
    where id = p_vote_id;

    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (
        v_vote.group_id,
        'voteResolved',
        p_vote_id,
        null,
        jsonb_build_object(
            'vote_type',    v_vote.vote_type,
            'reference_id', v_vote.reference_id,
            'resolution',   v_resolution
        )
    );

    insert into public.notifications_outbox (
        group_id, recipient_member_id, notification_type, payload, deep_link
    )
    select
        v_vote.group_id,
        vc.member_id,
        'voteResolved',
        jsonb_build_object(
            'vote_id',      p_vote_id,
            'vote_type',    v_vote.vote_type,
            'reference_id', v_vote.reference_id,
            'resolution',   v_resolution,
            'title',        v_vote.title
        ),
        'ruul://vote/' || p_vote_id::text
    from public.vote_casts vc
    where vc.vote_id = p_vote_id;

    if v_vote.vote_type = 'fine_appeal' then
        insert into public.notifications_outbox (
            group_id, recipient_member_id, notification_type, payload, deep_link
        )
        select
            v_vote.group_id,
            (v_vote.payload->>'member_id')::uuid,
            'voteResolved',
            jsonb_build_object(
                'vote_id',      p_vote_id,
                'vote_type',    v_vote.vote_type,
                'reference_id', v_vote.reference_id,
                'resolution',   v_resolution,
                'title',        v_vote.title,
                'is_appellant', true
            ),
            'ruul://vote/' || p_vote_id::text
        where v_vote.payload ? 'member_id'
          and (v_vote.payload->>'member_id') <> '';
    end if;

    if v_vote.vote_type = 'rule_change' and v_resolution = 'passed' then
        v_current_amount  := nullif(v_vote.payload->>'current_amount', '')::int;
        v_proposed_amount := nullif(v_vote.payload->>'proposed_amount', '')::int;

        if v_current_amount is null or v_proposed_amount is null then
            return v_resolution;
        end if;

        select gm.id, gm.user_id
          into v_founder_member_id, v_founder_user_id
          from public.group_members gm
         where gm.group_id = v_vote.group_id
           and gm.roles ?| array['founder']
           and gm.active = true
         order by gm.created_at asc
         limit 1;

        if v_founder_user_id is not null then
            v_rule_id := v_vote.reference_id;

            select coalesce(name, title, 'Regla #' || left(v_rule_id::text, 8))
              into v_rule_name
              from public.rules
             where id = v_rule_id;

            v_rule_name := coalesce(v_rule_name, 'Regla #' || left(v_rule_id::text, 8));

            insert into public.user_actions (
                user_id, group_id, action_type, reference_id,
                title, body, priority
            )
            select
                v_founder_user_id, v_vote.group_id, 'ruleChangeApplyPending', p_vote_id,
                'Aplicar cambio aprobado: ' || v_rule_name,
                format('Votado: $%s → $%s', v_current_amount, v_proposed_amount),
                'high'
            where not exists (
                select 1 from public.user_actions
                 where reference_id = p_vote_id
                   and action_type = 'ruleChangeApplyPending'
            );

            insert into public.notifications_outbox (
                group_id, recipient_member_id, notification_type, payload, deep_link
            )
            values (
                v_vote.group_id,
                v_founder_member_id,
                'ruleChangeApplyPending',
                jsonb_build_object(
                    'vote_id',         p_vote_id,
                    'rule_id',         v_rule_id,
                    'rule_name',       v_rule_name,
                    'current_amount',  v_current_amount,
                    'proposed_amount', v_proposed_amount,
                    'title',           'Aplicar cambio aprobado',
                    'body',            format('Votado: $%s → $%s', v_current_amount, v_proposed_amount)
                ),
                'ruul://rule/' || v_rule_id::text || '/edit?proposedAmount=' || v_proposed_amount::text
            );
        end if;
    end if;

    -- v4: fine_appeal resuelto → mutar fines.status + emitir appealResolved.
    -- §14 Step 3a: also emit fine_voided atom when resolution='passed'.
    if v_vote.vote_type = 'fine_appeal' then
        v_new_fine_status := case
            when v_resolution = 'passed'                     then 'voided'
            when v_resolution in ('failed', 'quorum_failed') then 'officialized'
            else null
        end;

        if v_new_fine_status is not null and v_vote.reference_id is not null then
            update public.fines
               set status        = v_new_fine_status,
                   waived        = (v_new_fine_status = 'voided'),
                   waived_at     = case when v_new_fine_status = 'voided' then now() else waived_at end,
                   waived_reason = case when v_new_fine_status = 'voided'
                                       then 'appeal_passed (vote ' || left(p_vote_id::text, 8) || ')'
                                       else waived_reason end,
                   updated_at    = now()
             where id     = v_vote.reference_id
               and status = 'in_appeal'
            returning amount, group_id, user_id, resource_id
              into v_fine_amount, v_fine_group_id, v_fine_user_id, v_fine_resource_id;

            get diagnostics v_fine_updated = row_count;

            if coalesce(v_fine_updated, 0) > 0 then
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
                        'new_fine_status', v_new_fine_status,
                        'amount',          v_fine_amount
                    )
                );

                update public.user_actions
                   set resolved_at = now()
                 where reference_id = v_vote.reference_id
                   and action_type  = 'finePending'
                   and resolved_at  is null;

                update public.user_actions
                   set resolved_at = now()
                 where reference_id = p_vote_id
                   and action_type  = 'appealVotePending'
                   and resolved_at  is null;

                -- §14 Step 3a: emit fine_voided atom (foundation for 3b
                -- projection). Only fires on actual void (resolution='passed').
                if v_new_fine_status = 'voided' then
                    SELECT id INTO v_fine_member_id
                    FROM public.group_members
                    WHERE group_id = v_fine_group_id AND user_id = v_fine_user_id
                    LIMIT 1;

                    INSERT INTO public.ledger_entries (
                        group_id, resource_id, type, amount_cents, currency,
                        from_member_id, to_member_id, metadata,
                        occurred_at, recorded_at, recorded_by
                    )
                    VALUES (
                        v_fine_group_id,
                        v_fine_resource_id,
                        'fine_voided',
                        (v_fine_amount * 100)::bigint,
                        'MXN',
                        v_fine_member_id,
                        NULL,
                        jsonb_build_object(
                            'fine_id', v_vote.reference_id,
                            'via',     'appeal',
                            'vote_id', p_vote_id,
                            'reason',  'appeal_passed (vote ' || left(p_vote_id::text, 8) || ')'
                        ),
                        now(),
                        now(),
                        NULL
                    );
                end if;
            end if;
        end if;
    end if;

    return v_resolution;
end;
$$;

COMMIT;
