-- 00239 — Reconcile silent-fail states in derived-fine-status model.
--
-- Closes governance-review item #3 ("fines status fragile").
--
-- Background
-- ==========
-- Mig 00151 dropped fines.status as a stored column. fines_view now
-- derives status from a precedence chain over ledger_entries + open
-- votes:
--
--   voided       ← exists ledger_entry(type=fine_voided, fine_id=X)
--   paid         ← exists ledger_entry(type=fine_paid,   fine_id=X)
--   in_appeal    ← exists open vote(vote_type=fine_appeal, reference=X)
--   officialized ← exists ledger_entry(type=fine_officialized, fine_id=X)
--   proposed     ← default
--
-- The derivation is elegant but has no single source of truth, which
-- creates silent-fail modes if any of the cron jobs that produce these
-- atoms breaks:
--
--   stuck_proposed       ← rule engine inserted fines row but the
--                          fine_officialized atom never fired (process-
--                          system-events crashed mid-loop). Fine is
--                          invisible to the appeal flow + ledger.
--
--   stuck_in_appeal      ← appeal vote stayed status='open' past its
--                          closes_at because the finalize-appeal-votes
--                          edge function failed (cold start, timeout,
--                          5xx). The fine reports in_appeal indefinitely
--                          and can't be paid/voided through the
--                          standard RPCs.
--
--   dual_atom            ← both fine_voided AND fine_paid emitted for
--                          the same fine. Should never happen; status
--                          precedence hides it but signals a race or
--                          double-write bug.
--
--   orphan_appeal_vote   ← open vote(fine_appeal) whose reference_id
--                          points to a deleted/non-existent fine. Vote
--                          will never resolve through the fine code
--                          path.
--
-- This migration ships
-- ====================
--   1. advise_stuck_fines() — pure read-only advisor returning one row
--      per anomaly. Safe to call from psql or future iOS admin tooling.
--      Threshold (hours_to_stuck) defaults to 24 for stuck_proposed.
--
--   2. reconcile_stuck_appeals() — calls finalize_vote(vote_id) for
--      every appeal vote that's still 'open' past its closes_at.
--      finalize_vote is idempotent (mig 00163 / 00023) so re-runs are
--      safe. Returns count of votes finalized.
--
--   3. cron job reconcile-stuck-appeals-30min — runs (2) every 30 min,
--      in-DB, so it's independent of the finalize-appeal-votes edge
--      function's HTTP path. Bounded silent-fail window: 30 min.
--
-- Deliberately NOT in scope
-- =========================
--   - Auto-remediating stuck_proposed (the rule engine owns
--     officialization; tampering here would mask the underlying bug).
--   - Auto-resolving dual_atom (data corruption — needs human review).
--   - Schema for an anomaly log table (advisor is callable on demand;
--     persistent storage adds maintenance without clear consumer yet).
--
-- Rollback: _rollbacks/00239_rollback.sql drops the functions and the
-- cron job.

-- =========================================================
-- 1. advise_stuck_fines() — read-only advisor
-- =========================================================
create or replace function public.advise_stuck_fines(
  p_hours_to_stuck int default 24
)
returns table (
  kind          text,
  fine_id       uuid,
  group_id      uuid,
  vote_id       uuid,
  age_hours     numeric,
  detail        jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  -- stuck_proposed: fines older than threshold without any progression atom.
  select
    'stuck_proposed'::text                                            as kind,
    f.id                                                              as fine_id,
    f.group_id                                                        as group_id,
    null::uuid                                                        as vote_id,
    extract(epoch from (now() - f.created_at))/3600.0                 as age_hours,
    jsonb_build_object(
      'created_at',     f.created_at,
      'amount',         f.amount,
      'auto_generated', f.auto_generated,
      'issued_by',      f.issued_by
    )                                                                 as detail
  from public.fines f
  where f.created_at < now() - (p_hours_to_stuck || ' hours')::interval
    and not exists (
      select 1 from public.ledger_entries le
       where le.type in ('fine_officialized','fine_paid','fine_voided')
         and (le.metadata->>'fine_id')::uuid = f.id
    )

  union all

  -- stuck_in_appeal: appeal vote open past closes_at.
  select
    'stuck_in_appeal'::text                                           as kind,
    f.id                                                              as fine_id,
    f.group_id                                                        as group_id,
    v.id                                                              as vote_id,
    extract(epoch from (now() - v.closes_at))/3600.0                  as age_hours,
    jsonb_build_object(
      'opened_at', v.opened_at,
      'closes_at', v.closes_at,
      'overdue_by_hours', extract(epoch from (now() - v.closes_at))/3600.0
    )                                                                 as detail
  from public.votes v
  join public.fines f on f.id = v.reference_id
  where v.vote_type = 'fine_appeal'
    and v.status    = 'open'
    and v.closes_at < now()

  union all

  -- dual_atom: both fine_voided AND fine_paid present for the same fine.
  select
    'dual_atom'::text                                                 as kind,
    f.id                                                              as fine_id,
    f.group_id                                                        as group_id,
    null::uuid                                                        as vote_id,
    extract(epoch from (now() - f.created_at))/3600.0                 as age_hours,
    jsonb_build_object(
      'paid_at',   (select le.occurred_at from public.ledger_entries le
                     where le.type='fine_paid'   and (le.metadata->>'fine_id')::uuid=f.id
                     order by le.occurred_at desc limit 1),
      'voided_at', (select le.occurred_at from public.ledger_entries le
                     where le.type='fine_voided' and (le.metadata->>'fine_id')::uuid=f.id
                     order by le.occurred_at desc limit 1)
    )                                                                 as detail
  from public.fines f
  where exists (
    select 1 from public.ledger_entries le
     where le.type='fine_paid'   and (le.metadata->>'fine_id')::uuid = f.id
  )
    and exists (
    select 1 from public.ledger_entries le
     where le.type='fine_voided' and (le.metadata->>'fine_id')::uuid = f.id
  )

  union all

  -- orphan_appeal_vote: open appeal vote whose reference_id is not a fine.
  select
    'orphan_appeal_vote'::text                                        as kind,
    null::uuid                                                        as fine_id,
    v.group_id                                                        as group_id,
    v.id                                                              as vote_id,
    extract(epoch from (now() - v.opened_at))/3600.0                  as age_hours,
    jsonb_build_object(
      'reference_id', v.reference_id,
      'opened_at',    v.opened_at,
      'closes_at',    v.closes_at,
      'title',        v.title
    )                                                                 as detail
  from public.votes v
  where v.vote_type = 'fine_appeal'
    and v.status    = 'open'
    and not exists (select 1 from public.fines f where f.id = v.reference_id)
  ;
$$;

revoke execute on function public.advise_stuck_fines(int) from public, anon;
grant  execute on function public.advise_stuck_fines(int) to authenticated, service_role;

comment on function public.advise_stuck_fines(int) is
  'Read-only advisor for governance-review item #3. Returns one row per anomalous fine state under the derived-status model (mig 00151). Kinds: stuck_proposed, stuck_in_appeal, dual_atom, orphan_appeal_vote. Threshold p_hours_to_stuck defaults to 24h for stuck_proposed.';

-- =========================================================
-- 2. reconcile_stuck_appeals() — auto-finalize expired appeals
-- =========================================================
create or replace function public.reconcile_stuck_appeals()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int := 0;
  v_id    uuid;
begin
  for v_id in
    select v.id
    from public.votes v
    where v.vote_type = 'fine_appeal'
      and v.status    = 'open'
      and v.closes_at < now()
    order by v.closes_at asc
  loop
    -- finalize_vote is idempotent (mig 00163): returns the cached
    -- resolution on a second call, never double-resolves.
    perform public.finalize_vote(v_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.reconcile_stuck_appeals() from public, anon;
grant  execute on function public.reconcile_stuck_appeals() to authenticated, service_role;

comment on function public.reconcile_stuck_appeals() is
  'Finalizes appeal votes that are still open past their closes_at — protects against silent fails in the finalize-appeal-votes edge function. Idempotent (finalize_vote handles already-resolved). Returns count of votes finalized.';

-- =========================================================
-- 3. Cron schedule: every 30 min
-- =========================================================
-- pg_cron lives in pg_catalog in this project (verified 2026-05-17).
-- cron.schedule is upsert-by-name so re-applies are idempotent.
select cron.schedule(
  'reconcile-stuck-appeals-30min',
  '*/30 * * * *',
  $cron$
    select public.reconcile_stuck_appeals();
  $cron$
);
