-- 00146 — Beta 1 Consolidation W3-E3: pay_fine is atomic + race-safe.
--
-- Bug
-- ===
-- The current pay_fine RPC (mig 00003:235-251) does:
--
--   1. SELECT * FROM fines WHERE id = p_fine_id;       -- unlocked
--   2. IF f.paid THEN RETURN; END IF;
--   3. UPDATE fines SET paid = true, paid_at = now(), ...
--   4. IF g.fund_enabled THEN
--        UPDATE groups SET fund_balance = fund_balance + f.amount WHERE id = g.id;
--      END IF;
--
-- Steps 1 and 2 are NOT serialized against a concurrent pay_fine call.
-- Two threads can both pass step 2 with paid=false, both execute the
-- UPDATE in step 3 (the second is a harmless idempotent write — paid
-- already true), but BOTH execute step 4, incrementing fund_balance
-- twice for a single fine.
--
-- Audit Track E High #1.
--
-- Real-world trigger: user double-taps the "Pagar" button on iOS
-- while the network is slow. iOS coordinators throttle reasonably
-- well but the surface is exposed.
--
-- Fix
-- ===
-- mig 00146 acquires `SELECT ... FOR UPDATE` on the fines row before
-- reading paid. Postgres serializes concurrent calls on the same row:
-- thread B blocks at step 1 until thread A commits, then re-reads
-- with paid=true and short-circuits at step 2.
--
-- Defense in depth:
--   - WHERE id = p_fine_id AND paid = false on the UPDATE, plus
--     GET DIAGNOSTICS row_count. If we lost the race (paid already
--     true), we never execute the fund_balance increment.
--   - Atomic `fund_balance = fund_balance + f.amount` in the same
--     statement (was already atomic; left intact).
--
-- Idempotent CREATE OR REPLACE — safe to re-apply.

create or replace function public.pay_fine(p_fine_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.fines;
  g public.groups;
  v_updated int;
begin
  -- W3-E3 fix: FOR UPDATE serializes against concurrent pay_fine calls
  -- on the same row.
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

  -- Idempotent return: a concurrent pay_fine call that landed first
  -- has already set paid=true; we re-read it under the row lock so
  -- this branch reliably catches the "second writer" case.
  if f.paid then return; end if;

  -- Defensive WHERE guard: even if some future caller bypasses
  -- FOR UPDATE, this clause prevents a stale-snapshot double-pay.
  update public.fines
     set paid          = true,
         paid_at       = now(),
         paid_to_fund  = g.fund_enabled
   where id   = p_fine_id
     and paid = false;

  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    -- Another caller paid this fine between our SELECT FOR UPDATE
    -- and the UPDATE. The lock should have prevented this, but the
    -- guard means we never increment fund_balance for a fine we
    -- didn't actually pay.
    return;
  end if;

  if g.fund_enabled then
    update public.groups
       set fund_balance = fund_balance + f.amount
     where id = g.id;
  end if;
end;
$$;

comment on function public.pay_fine(uuid) is
  'v2 (W3-E3, mig 00146): pay a fine atomically. Takes SELECT FOR UPDATE on the fines row + idempotent WHERE paid=false guard + row_count check before incrementing fund_balance. Prevents the double-tap race that previously could double-credit the common fund for a single fine.';
