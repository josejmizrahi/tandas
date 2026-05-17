-- 00239 — Reconcile silent-fail states in derived-fine-status model.

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
  select
    'stuck_proposed'::text,
    f.id, f.group_id, null::uuid,
    extract(epoch from (now() - f.created_at))/3600.0,
    jsonb_build_object(
      'created_at', f.created_at,
      'amount', f.amount,
      'auto_generated', f.auto_generated,
      'issued_by', f.issued_by
    )
  from public.fines f
  where f.created_at < now() - (p_hours_to_stuck || ' hours')::interval
    and not exists (
      select 1 from public.ledger_entries le
       where le.type in ('fine_officialized','fine_paid','fine_voided')
         and (le.metadata->>'fine_id')::uuid = f.id
    )

  union all

  select
    'stuck_in_appeal'::text,
    f.id, f.group_id, v.id,
    extract(epoch from (now() - v.closes_at))/3600.0,
    jsonb_build_object(
      'opened_at', v.opened_at,
      'closes_at', v.closes_at,
      'overdue_by_hours', extract(epoch from (now() - v.closes_at))/3600.0
    )
  from public.votes v
  join public.fines f on f.id = v.reference_id
  where v.vote_type = 'fine_appeal'
    and v.status    = 'open'
    and v.closes_at < now()

  union all

  select
    'dual_atom'::text,
    f.id, f.group_id, null::uuid,
    extract(epoch from (now() - f.created_at))/3600.0,
    jsonb_build_object(
      'paid_at', (select le.occurred_at from public.ledger_entries le where le.type='fine_paid' and (le.metadata->>'fine_id')::uuid=f.id order by le.occurred_at desc limit 1),
      'voided_at', (select le.occurred_at from public.ledger_entries le where le.type='fine_voided' and (le.metadata->>'fine_id')::uuid=f.id order by le.occurred_at desc limit 1)
    )
  from public.fines f
  where exists (select 1 from public.ledger_entries le where le.type='fine_paid'   and (le.metadata->>'fine_id')::uuid = f.id)
    and exists (select 1 from public.ledger_entries le where le.type='fine_voided' and (le.metadata->>'fine_id')::uuid = f.id)

  union all

  select
    'orphan_appeal_vote'::text,
    null::uuid, v.group_id, v.id,
    extract(epoch from (now() - v.opened_at))/3600.0,
    jsonb_build_object(
      'reference_id', v.reference_id,
      'opened_at', v.opened_at,
      'closes_at', v.closes_at,
      'title', v.title
    )
  from public.votes v
  where v.vote_type = 'fine_appeal'
    and v.status    = 'open'
    and not exists (select 1 from public.fines f where f.id = v.reference_id);
$$;

revoke execute on function public.advise_stuck_fines(int) from public, anon;
grant  execute on function public.advise_stuck_fines(int) to authenticated, service_role;

comment on function public.advise_stuck_fines(int) is
  'Read-only advisor for governance-review item #3. Returns one row per anomalous fine state under the derived-status model (mig 00151). Kinds: stuck_proposed, stuck_in_appeal, dual_atom, orphan_appeal_vote.';

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
    select v.id from public.votes v
     where v.vote_type = 'fine_appeal'
       and v.status    = 'open'
       and v.closes_at < now()
     order by v.closes_at asc
  loop
    perform public.finalize_vote(v_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.reconcile_stuck_appeals() from public, anon;
grant  execute on function public.reconcile_stuck_appeals() to authenticated, service_role;

comment on function public.reconcile_stuck_appeals() is
  'Finalizes appeal votes that are still open past closes_at — protects against silent fails in the finalize-appeal-votes edge function. Idempotent (finalize_vote handles already-resolved). Returns count finalized.';

select cron.schedule(
  'reconcile-stuck-appeals-30min',
  '*/30 * * * *',
  $cron$ select public.reconcile_stuck_appeals(); $cron$
);
