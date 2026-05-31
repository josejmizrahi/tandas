-- 00136 — Tier 6 slice: balance projection views.
--
-- Read-time aggregation over `public.ledger_entries`. No cache, no
-- snapshot table — the views compute on every call so they always
-- reflect the latest state. For V1 group sizes (≤500 members,
-- ≤10k entries/group) this is fast enough; if it isn't, snapshot
-- materialization comes as a later slice (cron-driven, refreshes a
-- `balance_snapshots` table).
--
-- Semantics
-- =========
-- Each `ledger_entries` row is a money atom with `from_member_id`
-- (who paid out) and `to_member_id` (who received). Either side may
-- be NULL — `from=NULL` means the group/fund paid out; `to=NULL`
-- means money went to the group/fund.
--
-- Per-member net for a scope (group or resource):
--   sent_cents      = sum(amount_cents where from_member_id = member.id)
--   received_cents  = sum(amount_cents where to_member_id   = member.id)
--   net_cents       = received_cents - sent_cents
--
-- Net interpretation:
--   net > 0  →  member is owed (received more than sent)
--   net < 0  →  member owes (sent more than received)
--   net = 0  →  even
--
-- This is the **neutral** framing — clients render it according to
-- their UX (some templates flip "expense paid by X" into "group owes
-- X", others count it as "X spent for the group"). The view keeps
-- the math; the iOS app decides the human label.
--
-- Multi-currency
-- ==============
-- ledger_entries has a `currency` column. Aggregating across
-- currencies is meaningless — we group by currency. iOS callers
-- that only care about the group's single primary currency
-- (groups.currency) filter to that row.
--
-- RLS
-- ===
-- Views inherit security_invoker = on, so the caller's RLS policy on
-- ledger_entries applies. Mig 00078 / 00082 grants SELECT to authed
-- users via `is_group_member`; the views compose cleanly on top.
-- No view-level grant change needed.

-- =========================================================
-- 1. Group-level balance per member
-- =========================================================
create or replace view public.member_balances_per_group
with (security_invoker = on)
as
with sent as (
  select
    le.group_id,
    le.from_member_id      as member_id,
    le.currency,
    sum(le.amount_cents)   as sent_cents
  from public.ledger_entries le
  where le.from_member_id is not null
  group by le.group_id, le.from_member_id, le.currency
),
received as (
  select
    le.group_id,
    le.to_member_id        as member_id,
    le.currency,
    sum(le.amount_cents)   as received_cents
  from public.ledger_entries le
  where le.to_member_id is not null
  group by le.group_id, le.to_member_id, le.currency
)
select
  coalesce(s.group_id,  r.group_id)  as group_id,
  coalesce(s.member_id, r.member_id) as member_id,
  coalesce(s.currency,  r.currency)  as currency,
  coalesce(s.sent_cents,     0::bigint) as sent_cents,
  coalesce(r.received_cents, 0::bigint) as received_cents,
  coalesce(r.received_cents, 0::bigint)
    - coalesce(s.sent_cents, 0::bigint)         as net_cents
from sent s
full outer join received r
  on  s.group_id  = r.group_id
  and s.member_id = r.member_id
  and s.currency  = r.currency;

comment on view public.member_balances_per_group is
  'Per-member net balance across the whole group (all resources). Reads ledger_entries at call time, no caching. net_cents > 0 = member is owed; < 0 = member owes. Multi-currency: one row per (group, member, currency). RLS via security_invoker — caller needs group_members visibility.';

-- =========================================================
-- 2. Resource-level balance per member
-- =========================================================
-- Same shape as the group view, but scoped to a single resource.
-- For event/booking/fund resources this is "how much each member
-- has put in / taken out FOR THIS RESOURCE". Entries with
-- resource_id IS NULL are excluded — they're group-level only.
create or replace view public.member_balances_per_resource
with (security_invoker = on)
as
with sent as (
  select
    le.resource_id,
    le.group_id,
    le.from_member_id      as member_id,
    le.currency,
    sum(le.amount_cents)   as sent_cents
  from public.ledger_entries le
  where le.resource_id    is not null
    and le.from_member_id is not null
  group by le.resource_id, le.group_id, le.from_member_id, le.currency
),
received as (
  select
    le.resource_id,
    le.group_id,
    le.to_member_id        as member_id,
    le.currency,
    sum(le.amount_cents)   as received_cents
  from public.ledger_entries le
  where le.resource_id  is not null
    and le.to_member_id is not null
  group by le.resource_id, le.group_id, le.to_member_id, le.currency
)
select
  coalesce(s.resource_id, r.resource_id) as resource_id,
  coalesce(s.group_id,    r.group_id)    as group_id,
  coalesce(s.member_id,   r.member_id)   as member_id,
  coalesce(s.currency,    r.currency)    as currency,
  coalesce(s.sent_cents,     0::bigint)  as sent_cents,
  coalesce(r.received_cents, 0::bigint)  as received_cents,
  coalesce(r.received_cents, 0::bigint)
    - coalesce(s.sent_cents, 0::bigint)           as net_cents
from sent s
full outer join received r
  on  s.resource_id = r.resource_id
  and s.group_id    = r.group_id
  and s.member_id   = r.member_id
  and s.currency    = r.currency;

comment on view public.member_balances_per_resource is
  'Per-member net balance scoped to a single resource (event / booking / fund). Excludes group-level entries (resource_id IS NULL). Same shape + semantics as member_balances_per_group. Tier 6 slice 18 / mig 00136.';
