-- 00353 — issue_manual_fine retry-idempotent via p_client_id.
--
-- Bug (V1-03, FASE 0 correctness sprint)
-- ======================================
-- issue_manual_fine has no idempotency key. iOS has no automatic retry —
-- the admin's "retry" is re-tapping "Multar" after seeing a network error.
-- Each re-tap fires a fresh RPC, which:
--   1. INSERTs a new row into `fines` (new id).
--   2. INSERTs a new row into `ledger_entries` (type='fine_officialized').
-- → the same person ends up with two duplicate fines on the books, the
-- ledger acknowledges both, and any projection that sums fine totals
-- doubles.
--
-- Founder doctrine: "Un race que duplique multas destruye confianza
-- sistémica." Mirrors V1-01 (mig 00351 fund_contribute / fund_record_expense).
--
-- Design — mirror V1-01 with one twist
-- ====================================
-- V1-01 had a single INSERT (ledger_entries). V1-03 has TWO inserts
-- (fines + ledger_entries) that must succeed-or-fail atomically. Naively
-- wrapping only the ledger INSERT in a BEGIN/EXCEPTION savepoint would
-- leave the fines INSERT committed if the ledger raises unique_violation
-- — an orphan fine row. So we wrap BOTH inserts inside the inner
-- BEGIN/EXCEPTION: a unique_violation on the ledger rolls the savepoint
-- back, undoing the fines INSERT too, and we then look up the parallel
-- caller's prior fine via their ledger entry.
--
-- We reuse the partial unique index `ledger_entries_client_id_unique`
-- (mig 00351) — namespace is global by design. No new index.
--
-- Behavior
-- ========
--   1st call, p_client_id=A → INSERT fine F1 + ledger L1; return F1.
--   2nd call, p_client_id=A → EXISTS pre-check fires → return F1 (no new rows).
--   2nd call concurrent with 1st (race past EXISTS) → ledger INSERT
--     raises unique_violation → savepoint rolls back both inserts →
--     re-fetch parallel caller's fine via their L_winner.metadata.fine_id
--     → return F_winner.
--   call with p_client_id=null → INSERT new fine + new ledger each time
--     (legacy path, no dedup).
--
-- Backwards-compatible — `p_client_id uuid default null`. Mig 00354
-- drops the 6-arg legacy overload so PostgREST has only one route.

create or replace function public.issue_manual_fine(
  p_group_id    uuid,
  p_user_id     uuid,
  p_amount      numeric,
  p_reason      text,
  p_rule_id     uuid default null,
  p_resource_id uuid default null,
  p_client_id   uuid default null
)
returns public.fines
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  f                   public.fines;
  r                   public.rules;
  v_snapshot          jsonb;
  v_member_id         uuid;
  v_existing_fine_id  uuid;
  v_ledger_metadata   jsonb;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if not public.has_permission(p_group_id, auth.uid(), 'issueFine') then
    raise exception 'issueFine permission required' using errcode = '42501';
  end if;
  if not public.is_group_member(p_group_id, p_user_id) then raise exception 'target user not a member'; end if;
  if p_amount < 0 then raise exception 'amount must be non-negative'; end if;
  if length(coalesce(p_reason, '')) < 2 then raise exception 'reason required'; end if;

  -- V1-03 optimistic idempotency check (pre-INSERT). If a prior ledger
  -- entry for this client_id exists, fetch its source fine and return.
  if p_client_id is not null then
    select (le.metadata->>'fine_id')::uuid into v_existing_fine_id
      from public.ledger_entries le
     where (le.metadata->>'client_id') = p_client_id::text
     limit 1;
    if v_existing_fine_id is not null then
      select * into f from public.fines where id = v_existing_fine_id;
      if f.id is not null then
        return f;
      end if;
    end if;
  end if;

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

  v_ledger_metadata := jsonb_build_object(
    'rule_id', p_rule_id,
    'via',     'issue_manual_fine'
  );
  if p_client_id is not null then
    v_ledger_metadata := v_ledger_metadata || jsonb_build_object('client_id', p_client_id);
  end if;

  -- V1-03 race-safe atomicity: wrap BOTH inserts inside one inner
  -- BEGIN/EXCEPTION block. The implicit SAVEPOINT means a unique_violation
  -- on the ledger INSERT rolls back the fines INSERT too — no orphan row.
  begin
    insert into public.fines (
      group_id, user_id, amount, reason, rule_id, resource_id,
      auto_generated, issued_by, rule_snapshot
    )
    values (
      p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_resource_id,
      false, auth.uid(), v_snapshot
    )
    returning * into f;

    select id into v_member_id from public.group_members
     where group_id = f.group_id and user_id = f.user_id limit 1;

    insert into public.ledger_entries (
      group_id, resource_id, type, amount_cents, currency,
      from_member_id, to_member_id, metadata,
      occurred_at, recorded_at, recorded_by
    )
    values (
      f.group_id, f.resource_id, 'fine_officialized', (f.amount * 100)::bigint, 'MXN',
      v_member_id, null,
      v_ledger_metadata || jsonb_build_object('fine_id', f.id),
      now(), now(), auth.uid()
    );
  exception when unique_violation then
    -- A parallel caller inserted between our EXISTS check and our INSERT.
    -- Savepoint rolls back BOTH our INSERTs. Look up the winning caller's
    -- fine via their ledger entry's metadata.client_id and return it.
    if p_client_id is not null then
      select (le.metadata->>'fine_id')::uuid into v_existing_fine_id
        from public.ledger_entries le
       where (le.metadata->>'client_id') = p_client_id::text
       limit 1;
      if v_existing_fine_id is not null then
        select * into f from public.fines where id = v_existing_fine_id;
        if f.id is not null then
          return f;
        end if;
      end if;
    end if;
    raise;
  end;

  return f;
end;
$function$;

comment on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid, uuid) is
  'v2 (V1-03, mig 00353): retry-idempotent via p_client_id (default null, backwards-compat). EXISTS pre-check + atomic two-INSERT savepoint with unique_violation catch. Reuses ledger_entries_client_id_unique index from mig 00351.';
