-- =============================================================================
-- _smoke_r4c_ledger — verifies R.4C deliverables end-to-end.
-- =============================================================================
-- Asserted cases:
--   C1  ledger_entries table + indexes + RLS exist
--   C2  actor_money_balances view exists + readable
--   C3  trigger money_splits_emit_ledger registered on money_splits
--   C4  expense splits emit correct credit/debit rows via trigger
--   C5  per-context net sum is zero (with rounding tolerance)
--   C6  actor_money_balances reflects expected per-actor net balances
--   C7  unknown role combinations silently produce no ledger row
--   C8  payment splits emit correctly: payer→credit, creditor→debit
-- =============================================================================
create or replace function public._smoke_r4c_ledger()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_auth_c uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_c uuid;
  v_familia uuid;
  v_txn uuid := gen_random_uuid();
  v_pmt uuid := gen_random_uuid();
  v_credit_count int;
  v_debit_count int;
  v_net numeric;
  v_a_balance numeric;
  v_b_balance numeric;
  v_c_balance numeric;
  v_pre_pmt_count int;
  v_post_pmt_count int;
  v_unknown_row int;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, '_smoke_r4c A', '+520000000950', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, '_smoke_r4c B', '+520000000951', null);
  v_c := public._create_person_actor_for_auth_user(v_auth_c, '_smoke_r4c C', '+520000000952', null);

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_a::text)::text, true);

  v_familia := (
    public.create_context('_smoke_r4c Familia','collective','family')->>'context_actor_id'
  )::uuid;

  -- ---------------------------------------------------------------------------
  -- C1: schema present
  -- ---------------------------------------------------------------------------
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='ledger_entries') then
    raise exception 'r4c C1: ledger_entries table missing';
  end if;
  if not exists (select 1 from pg_indexes
                 where schemaname='public' and indexname='idx_ledger_context_actor_currency') then
    raise exception 'r4c C1b: idx_ledger_context_actor_currency missing';
  end if;
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname='public' and c.relname='ledger_entries' and c.relrowsecurity = true
  ) then
    raise exception 'r4c C1c: RLS not enabled on ledger_entries';
  end if;

  -- ---------------------------------------------------------------------------
  -- C2: view exists
  -- ---------------------------------------------------------------------------
  if not exists (select 1 from information_schema.views
                 where table_schema='public' and table_name='actor_money_balances') then
    raise exception 'r4c C2: actor_money_balances view missing';
  end if;

  -- ---------------------------------------------------------------------------
  -- C3: trigger registered
  -- ---------------------------------------------------------------------------
  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
    where c.relname='money_splits'
      and p.proname='_emit_ledger_from_split'
      and not t.tgisinternal
  ) then
    raise exception 'r4c C3: money_splits_emit_ledger trigger missing';
  end if;

  -- ---------------------------------------------------------------------------
  -- C4 + C5 + C6: end-to-end expense — A paid 90 MXN; equal split A+B+C
  -- Each share = 30 MXN. Expected:
  --   A: credit 90, debit 30 → net +60
  --   B: debit 30           → net -30
  --   C: debit 30           → net -30
  --   sum = 0
  -- ---------------------------------------------------------------------------
  insert into public.money_transactions(id, context_actor_id, transaction_type,
    amount, currency, status, occurred_at, created_by_actor_id)
  values (v_txn, v_familia, 'expense', 90, 'MXN', 'posted', now(), v_a);

  insert into public.money_splits(transaction_id, actor_id, split_role, amount, currency)
  values (v_txn, v_a, 'payer', 90, 'MXN'),
         (v_txn, v_a, 'beneficiary', 30, 'MXN'),
         (v_txn, v_b, 'beneficiary', 30, 'MXN'),
         (v_txn, v_c, 'beneficiary', 30, 'MXN');

  select count(*) filter (where entry_type='credit'),
         count(*) filter (where entry_type='debit')
    into v_credit_count, v_debit_count
    from public.ledger_entries where transaction_id = v_txn;
  if v_credit_count <> 1 or v_debit_count <> 3 then
    raise exception 'r4c C4: expected 1 credit + 3 debits for expense, got % + %',
      v_credit_count, v_debit_count;
  end if;

  -- C5: per-context net is zero (no rounding for these clean values)
  select sum(case entry_type when 'credit' then amount else -amount end)
    into v_net
    from public.ledger_entries where context_actor_id = v_familia and currency = 'MXN';
  if v_net <> 0 then
    raise exception 'r4c C5: net sum per context not zero (got %)', v_net;
  end if;

  -- C6: per-actor balances from the view
  select net_balance into v_a_balance from public.actor_money_balances
   where context_actor_id = v_familia and actor_id = v_a and currency = 'MXN';
  select net_balance into v_b_balance from public.actor_money_balances
   where context_actor_id = v_familia and actor_id = v_b and currency = 'MXN';
  select net_balance into v_c_balance from public.actor_money_balances
   where context_actor_id = v_familia and actor_id = v_c and currency = 'MXN';

  if v_a_balance <> 60 then
    raise exception 'r4c C6a: A balance expected 60, got %', v_a_balance;
  end if;
  if v_b_balance <> -30 then
    raise exception 'r4c C6b: B balance expected -30, got %', v_b_balance;
  end if;
  if v_c_balance <> -30 then
    raise exception 'r4c C6c: C balance expected -30, got %', v_c_balance;
  end if;

  -- ---------------------------------------------------------------------------
  -- C7: unknown role combination produces no ledger row
  -- ---------------------------------------------------------------------------
  select count(*) into v_pre_pmt_count from public.ledger_entries where transaction_id = v_txn;
  insert into public.money_splits(transaction_id, actor_id, split_role, amount, currency)
  values (v_txn, v_a, 'unknown_role_xyz', 1, 'MXN');
  select count(*) into v_unknown_row from public.ledger_entries
    where transaction_id = v_txn;
  if v_unknown_row <> v_pre_pmt_count then
    raise exception 'r4c C7: unknown split_role unexpectedly emitted a ledger row (pre=% post=%)',
      v_pre_pmt_count, v_unknown_row;
  end if;

  -- ---------------------------------------------------------------------------
  -- C8: payment B → A for 30 MXN settles B's debt.
  -- Expected: B credit 30 (paying) → net B: -30 + 30 = 0
  --           A debit 30 (received) → net A: +60 - 30 = +30
  -- ---------------------------------------------------------------------------
  insert into public.money_transactions(id, context_actor_id, transaction_type,
    amount, currency, status, occurred_at, created_by_actor_id, from_actor_id, to_actor_id)
  values (v_pmt, v_familia, 'payment', 30, 'MXN', 'posted', now(), v_b, v_b, v_a);

  insert into public.money_splits(transaction_id, actor_id, split_role, amount, currency)
  values (v_pmt, v_b, 'payer', 30, 'MXN'),
         (v_pmt, v_a, 'creditor', 30, 'MXN');

  select net_balance into v_a_balance from public.actor_money_balances
   where context_actor_id = v_familia and actor_id = v_a and currency = 'MXN';
  select net_balance into v_b_balance from public.actor_money_balances
   where context_actor_id = v_familia and actor_id = v_b and currency = 'MXN';
  if v_a_balance <> 30 then
    raise exception 'r4c C8a: A balance after payment expected 30, got %', v_a_balance;
  end if;
  if v_b_balance <> 0 then
    raise exception 'r4c C8b: B balance after payment expected 0, got %', v_b_balance;
  end if;

  -- ---------------------------------------------------------------------------
  -- Cleanup. ledger_entries deletes cascade through money_transactions FK.
  -- ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', null, true);

  delete from public.money_splits where transaction_id in (v_txn, v_pmt);
  delete from public.ledger_entries where transaction_id in (v_txn, v_pmt);
  delete from public.money_transactions where id in (v_txn, v_pmt);
  delete from public.role_assignments where context_actor_id = v_familia;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_familia;
  delete from public.roles where context_actor_id = v_familia;
  delete from public.actor_memberships where context_actor_id = v_familia;
  delete from public.actors where id = v_familia;
  delete from public.person_profiles where actor_id in (v_a, v_b, v_c);
  delete from public.actors where id in (v_a, v_b, v_c);
  delete from auth.users where id in (v_auth_a, v_auth_b, v_auth_c);

  raise notice '_smoke_r4c_ledger passed (8 casos)';
end;
$$;

revoke all on function public._smoke_r4c_ledger() from anon;
grant execute on function public._smoke_r4c_ledger() to service_role;
