-- Mig 00201 — Asset universal projections (canonical asset spec §14).
--
-- Per the spec, projections derive entirely from the append-only atom
-- stream emitted by the RPCs in mig 00200 (and assetCreated /
-- bookingCreated / resourceArchived from earlier migrations).
--
-- Four projections ship here, all `security_invoker=on` so RLS on
-- `system_events` + `resources` applies as if the caller had read the
-- base tables directly:
--
--   1. asset_current_custodian_view
--      Latest custody.assigned for an asset, when no later
--      custody.released has fired.
--
--   2. asset_valuation_view
--      Latest valuation.recorded per asset.
--
--   3. asset_maintenance_status_view
--      Open maintenance.logged events (no matching maintenance.completed).
--      Surfaces "service overdue" / "needs repair" badges.
--
--   4. asset_usage_history_view
--      Append-only feed of asset.used / asset.checked_out /
--      asset.checked_in / asset.transferred — feeds the Activity tab.
--
-- These are VIEWS not materialized — read volume is small (10s-100s of
-- atoms per asset over its lifetime) and freshness matters for the UI
-- (custody changes must reflect immediately).

-- =============================================================================
-- 1. asset_current_custodian_view
-- =============================================================================

create or replace view public.asset_current_custodian_view
with (security_invoker = on)
as
with assigns as (
  select
    se.resource_id      as asset_id,
    se.group_id,
    se.member_id        as custodian_member_id,
    se.occurred_at      as assigned_at,
    se.payload->>'assigned_by' as assigned_by_user_id,
    se.payload->>'notes' as notes,
    row_number() over (
      partition by se.resource_id
      order by se.occurred_at desc
    ) as rn
  from public.system_events se
  where se.event_type = 'custodyAssigned'
),
latest_release as (
  select
    se.resource_id  as asset_id,
    max(se.occurred_at) as released_at
  from public.system_events se
  where se.event_type = 'custodyReleased'
  group by se.resource_id
)
select
  a.asset_id,
  a.group_id,
  a.custodian_member_id,
  a.assigned_at,
  a.assigned_by_user_id,
  a.notes
from assigns a
left join latest_release lr on lr.asset_id = a.asset_id
where a.rn = 1
  and (lr.released_at is null or lr.released_at < a.assigned_at);

comment on view public.asset_current_custodian_view is
  'Asset spec §14 — current custodian per asset. Empty row = asset is in group-level custody (no individual holder). Derived from custodyAssigned / custodyReleased atoms.';

-- =============================================================================
-- 2. asset_valuation_view — latest recorded valuation per asset
-- =============================================================================

create or replace view public.asset_valuation_view
with (security_invoker = on)
as
with ranked as (
  select
    se.resource_id      as asset_id,
    se.group_id,
    (se.payload->>'value_cents')::bigint as value_cents,
    se.payload->>'currency' as currency,
    se.payload->>'source'   as source,
    se.payload->>'notes'    as notes,
    se.payload->>'recorded_by' as recorded_by_user_id,
    se.occurred_at      as recorded_at,
    row_number() over (
      partition by se.resource_id
      order by se.occurred_at desc
    ) as rn
  from public.system_events se
  where se.event_type = 'valuationRecorded'
)
select
  asset_id,
  group_id,
  value_cents,
  currency,
  source,
  notes,
  recorded_by_user_id,
  recorded_at
from ranked
where rn = 1;

comment on view public.asset_valuation_view is
  'Asset spec §14/§16 — latest valuation per asset. History lives in system_events (appended); this view is the spot value.';

-- =============================================================================
-- 3. asset_maintenance_status_view — open maintenance items per asset
-- =============================================================================

create or replace view public.asset_maintenance_status_view
with (security_invoker = on)
as
with logged as (
  select
    se.id               as maintenance_event_id,
    se.resource_id      as asset_id,
    se.group_id,
    se.payload->>'kind' as kind,
    se.payload->>'notes' as notes,
    nullif(se.payload->>'cost_cents', '')::bigint as cost_cents,
    se.payload->>'currency' as currency,
    se.payload->>'logged_by' as logged_by_user_id,
    se.occurred_at      as logged_at
  from public.system_events se
  where se.event_type = 'maintenanceLogged'
),
completed as (
  select distinct
    (se.payload->>'maintenance_event_id')::uuid as maintenance_event_id
  from public.system_events se
  where se.event_type = 'maintenanceCompleted'
    and se.payload ? 'maintenance_event_id'
)
select
  l.maintenance_event_id,
  l.asset_id,
  l.group_id,
  l.kind,
  l.notes,
  l.cost_cents,
  l.currency,
  l.logged_by_user_id,
  l.logged_at
from logged l
left join completed c using (maintenance_event_id)
where c.maintenance_event_id is null;

comment on view public.asset_maintenance_status_view is
  'Asset spec §14 — open maintenance items per asset (logged but not completed). Closed items stay in system_events as historical record.';

-- =============================================================================
-- 4. asset_usage_history_view — append-only activity feed
-- =============================================================================

create or replace view public.asset_usage_history_view
with (security_invoker = on)
as
select
  se.id              as event_id,
  se.resource_id     as asset_id,
  se.group_id,
  se.event_type,
  se.member_id,
  se.payload,
  se.occurred_at
from public.system_events se
where se.event_type in (
  'assetCreated',
  'assetTransferred',
  'assetAssigned',
  'assetReturned',
  'assetUsed',
  'assetCheckedOut',
  'assetCheckedIn',
  'custodyAssigned',
  'custodyReleased',
  'maintenanceLogged',
  'maintenanceCompleted',
  'damageReported',
  'valuationRecorded',
  'bookingCreated',
  'bookingCancelled',
  'bookingExpired',
  'resourceArchived',
  'resourceUnarchived',
  'resourceRenamed'
);

comment on view public.asset_usage_history_view is
  'Asset spec §14/§22 Activity tab — append-only feed of every asset-relevant atom. Subset filter on system_events keeps the iOS query simple (one WHERE on event_type catalog).';
