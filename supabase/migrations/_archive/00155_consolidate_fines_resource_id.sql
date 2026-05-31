-- 00155 — Consolidate fines / fine_review_periods on resource_id.
--
-- Constitution §14 step 5c-ii.
--
-- State today (2026-05-13)
-- ========================
-- - public.fines has two columns naming the same UUID: event_id (FK →
--   events.id, ON DELETE SET NULL) and resource_id (FK → resources.id,
--   ON DELETE SET NULL). All 19 prod rows have both populated with the
--   same value.
-- - public.fine_review_periods has the same dual columns: event_id (FK
--   → events.id ON DELETE CASCADE, populated 7/7) and resource_id (FK
--   → resources.id ON DELETE CASCADE, populated 0/7).
-- - The dual-write predates §14 — the resource_id columns were added
--   when Phase 2 introduced non-event resources (mig 00041), but the
--   legacy event_id columns kept working in lockstep because every
--   event mirrors 1:1 to resources via the 00039 dual-write trigger.
--
-- After this migration
-- ====================
-- - fines.event_id and fine_review_periods.event_id are dropped, along
--   with their FK constraints to events.id.
-- - Every reader / writer / projection uses resource_id exclusively.
-- - Two of the four FKs to events.id from the §14 step 5c audit are
--   gone. The remaining two (event_attendance.event_id self-ref and
--   events.parent_event_id self-ref) drop with their tables in 5c-iv.
-- - The events table is now FK-pointed-to only by the soon-to-be-
--   dropped event_attendance / events self-ref, unblocking 5c-iv to
--   issue DROP TABLE events.
--
-- This migration also forward-compatibly updates the three RPCs that
-- still queried events for host_id checks: officialize_fine,
-- on_fine_inserted. They now read host_id from resources.metadata
-- (the dual-write trigger has kept this in sync since 00039). One
-- less reference to public.events to clean up in 5c-iv.
--
-- Idempotency
-- ===========
-- - Backfill is `where resource_id is null` guarded.
-- - DROP CONSTRAINT IF EXISTS + DROP COLUMN IF EXISTS.
-- - CREATE OR REPLACE for views and functions.
-- - Unique index on fine_review_periods(resource_id) uses
--   CREATE UNIQUE INDEX IF NOT EXISTS.

-- =============================================================================
-- 1. Backfill fine_review_periods.resource_id from event_id (7 rows)
-- =============================================================================

update public.fine_review_periods
   set resource_id = event_id
 where resource_id is null
   and event_id    is not null;

-- =============================================================================
-- 2. Tighten constraints on fine_review_periods.resource_id
-- =============================================================================
-- After backfill every row is populated; lock it NOT NULL and add the
-- unique constraint that on_fine_inserted needs for ON CONFLICT.

alter table public.fine_review_periods
  alter column resource_id set not null;

-- The legacy unique index is backed by a UNIQUE CONSTRAINT (not just
-- an index), so dropping it has to go through ALTER TABLE … DROP
-- CONSTRAINT. Drop the constraint here so the column is free for the
-- DROP COLUMN below; the new unique on resource_id replaces it.
alter table public.fine_review_periods
  drop constraint if exists fine_review_periods_event_id_key;

create unique index if not exists fine_review_periods_resource_id_key
  on public.fine_review_periods(resource_id);

-- =============================================================================
-- 3. Drop fines.event_id and fine_review_periods.event_id
-- =============================================================================
-- DROP COLUMN cascades to the FK constraints; explicit drops below
-- make the intent obvious in code review.

alter table public.fine_review_periods
  drop constraint if exists fine_review_periods_event_id_fkey;

-- The RLS read policy referenced the legacy event_id column (and joined
-- public.events for membership). Recreate it on resource_id + resources
-- so it survives the column drop and the upcoming events table drop.
drop policy if exists "fine_review_periods_read_member" on public.fine_review_periods;
create policy "fine_review_periods_read_member" on public.fine_review_periods
  for select to authenticated
  using (
    exists (
      select 1
        from public.resources r
        join public.group_members gm on gm.group_id = r.group_id
       where r.id = fine_review_periods.resource_id
         and gm.user_id = auth.uid()
         and gm.active = true
    )
  );

alter table public.fine_review_periods
  drop column if exists event_id;

alter table public.fines
  drop constraint if exists fines_event_id_fkey;

-- fines_view (mig 00149 / 00151) currently selects f.event_id, so
-- DROP COLUMN fails with `view depends on column`. CREATE OR REPLACE
-- VIEW can't drop a projected column either — it has to be DROP +
-- CREATE. Drop first, then drop the column, then recreate the view
-- with the new (resource_id-only) shape below.
drop view if exists public.fines_view;

alter table public.fines
  drop column if exists event_id;

-- The non-unique partial index from mig 00041 is now the primary
-- access path. Keep it but it's redundant with the unique we just
-- created — drop the duplicate so DDL stays clean.
drop index if exists public.fine_review_periods_resource_id_idx;

-- =============================================================================
-- 4. Rebuild fines_view without event_id
-- =============================================================================
-- Identical to the 00149 / 00151 body minus the f.event_id projection.

create view public.fines_view as
SELECT
  id,
  group_id,
  user_id,
  rule_id,
  resource_id,
  reason,
  amount,
  CASE
    WHEN (EXISTS (SELECT 1
                    FROM ledger_entries le
                   WHERE le.type = 'fine_voided'::text
                     AND ((le.metadata ->> 'fine_id'::text)::uuid) = f.id)) THEN 'voided'::text
    WHEN (EXISTS (SELECT 1
                    FROM ledger_entries le
                   WHERE le.type = 'fine_paid'::text
                     AND ((le.metadata ->> 'fine_id'::text)::uuid) = f.id)) THEN 'paid'::text
    WHEN (EXISTS (SELECT 1
                    FROM votes v
                   WHERE v.vote_type = 'fine_appeal'::text
                     AND v.reference_id = f.id
                     AND v.status = 'open'::text)) THEN 'in_appeal'::text
    WHEN (EXISTS (SELECT 1
                    FROM ledger_entries le
                   WHERE le.type = 'fine_officialized'::text
                     AND ((le.metadata ->> 'fine_id'::text)::uuid) = f.id)) THEN 'officialized'::text
    ELSE 'proposed'::text
  END AS status,
  (EXISTS (SELECT 1
             FROM ledger_entries le
            WHERE le.type = 'fine_paid'::text
              AND ((le.metadata ->> 'fine_id'::text)::uuid) = f.id)) AS paid,
  (SELECT le.occurred_at
     FROM ledger_entries le
    WHERE le.type = 'fine_paid'::text
      AND ((le.metadata ->> 'fine_id'::text)::uuid) = f.id
    ORDER BY le.occurred_at DESC
    LIMIT 1) AS paid_at,
  (EXISTS (SELECT 1
             FROM ledger_entries le
            WHERE le.type = 'fine_voided'::text
              AND ((le.metadata ->> 'fine_id'::text)::uuid) = f.id)) AS waived,
  (SELECT le.occurred_at
     FROM ledger_entries le
    WHERE le.type = 'fine_voided'::text
      AND ((le.metadata ->> 'fine_id'::text)::uuid) = f.id
    ORDER BY le.occurred_at DESC
    LIMIT 1) AS waived_at,
  (SELECT le.metadata ->> 'reason'::text
     FROM ledger_entries le
    WHERE le.type = 'fine_voided'::text
      AND ((le.metadata ->> 'fine_id'::text)::uuid) = f.id
    ORDER BY le.occurred_at DESC
    LIMIT 1) AS waived_reason,
  auto_generated,
  issued_by,
  details,
  created_at,
  updated_at,
  rule_snapshot
FROM public.fines f;

comment on view public.fines_view is
  'Fines projection per Constitution §14 step 3b (now updated for 5c-ii). Status / paid / waived derived from ledger_entries atoms + votes + review_periods. resource_id is the canonical event-or-non-event handle; legacy event_id column was dropped in 5c-ii.';

grant select on public.fines_view to authenticated;

-- =============================================================================
-- 5. Refresh on_fine_inserted to use resource_id and read host from resources
-- =============================================================================

create or replace function public.on_fine_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_user_id uuid;
begin
  if new.auto_generated and new.resource_id is not null then
    insert into public.fine_review_periods (resource_id, expires_at)
    values (new.resource_id, now() + interval '24 hours')
    on conflict (resource_id) do nothing;

    select (r.metadata->>'host_id')::uuid
      into v_host_user_id
      from public.resources r
     where r.id = new.resource_id;

    if v_host_user_id is not null then
      insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
      ) values (
        v_host_user_id, new.group_id, 'fineProposalReview', new.resource_id,
        'Revisa multas propuestas',
        'Las multas se oficializan en 24 horas si no las revisas',
        'high'
      ) on conflict do nothing;
    end if;
  end if;
  return new;
end;
$$;

comment on function public.on_fine_inserted() is
  'After-insert trigger on fines: spawns a 24h review period and a host inbox row for auto-generated fines. Reads host_id from resources.metadata (forward-compatible past 5c-iv events drop). §14 step 5c-ii.';

-- =============================================================================
-- 6. Refresh on_fine_atom_inserted to use v_fine.resource_id
-- =============================================================================

create or replace function public.on_fine_atom_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fine        public.fines;
  v_fine_id     uuid;
  v_count_left  int;
begin
  if (NEW.metadata->>'backfilled')::boolean is true then
    return NEW;
  end if;

  v_fine_id := (NEW.metadata->>'fine_id')::uuid;
  if v_fine_id is null then return NEW; end if;

  select * into v_fine from public.fines where id = v_fine_id;
  if v_fine.id is null then return NEW; end if;

  case NEW.type
    when 'fine_officialized' then
      insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
      )
      values (
        v_fine.user_id, v_fine.group_id, 'finePending', v_fine.id,
        'Multa pendiente: $' || trim(to_char(v_fine.amount, 'FM999G999D00')),
        v_fine.reason, 'high'
      );

      perform public.record_system_event(
        v_fine.group_id, 'fineOfficialized', v_fine.id, null,
        jsonb_build_object('amount', v_fine.amount, 'rule_id', v_fine.rule_id)
      );

    when 'fine_paid' then
      update public.user_actions
         set resolved_at = now()
       where action_type = 'finePending'
         and reference_id = v_fine.id
         and resolved_at is null;

    when 'fine_voided' then
      update public.user_actions
         set resolved_at = now()
       where action_type = 'finePending'
         and reference_id = v_fine.id
         and resolved_at is null;

    else
      null;
  end case;

  if NEW.type in ('fine_officialized', 'fine_paid', 'fine_voided')
     and v_fine.resource_id is not null then
    select count(*) into v_count_left
      from public.fines_view fv
     where fv.resource_id = v_fine.resource_id
       and fv.status = 'proposed';
    if v_count_left = 0 then
      update public.user_actions
         set resolved_at = now()
       where action_type = 'fineProposalReview'
         and reference_id = v_fine.resource_id
         and resolved_at is null;
    end if;
  end if;

  return NEW;
end;
$$;

comment on function public.on_fine_atom_inserted() is
  'After-insert trigger on ledger_entries (fine_* types): drives inbox + system_events side-effects for fine atom transitions. §14 step 5c-ii: switched from v_fine.event_id to v_fine.resource_id.';

-- =============================================================================
-- 7. Refresh officialize_fine to use resource_id and resources.metadata->>host_id
-- =============================================================================

create or replace function public.officialize_fine(p_fine_id uuid)
returns public.fines
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.fines;
  uid uuid := auth.uid();
  v_member_id uuid;
  v_has_atom boolean;
  v_host_id uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select * into f from public.fines where id = p_fine_id for update;
  if f.id is null then raise exception 'fine not found'; end if;

  select exists (
    select 1 from public.ledger_entries le
     where le.type = 'fine_officialized' and (le.metadata->>'fine_id')::uuid = f.id
  ) into v_has_atom;
  if v_has_atom then return f; end if;

  select (r.metadata->>'host_id')::uuid
    into v_host_id
    from public.resources r
   where r.id = f.resource_id;

  if not (public.is_group_admin(f.group_id, uid)
        or (v_host_id is not null and v_host_id = uid)) then
    raise exception 'only host or admin can officialize this fine';
  end if;

  update public.fine_review_periods
     set officialized_at = now(),
         officialized_by = (select id from public.group_members where user_id = uid and group_id = f.group_id limit 1)
   where resource_id = f.resource_id and officialized_at is null;

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
    jsonb_build_object('fine_id', f.id, 'rule_id', f.rule_id, 'via', 'officialize_fine_rpc'),
    now(), now(), uid
  );

  return f;
end;
$$;

comment on function public.officialize_fine(uuid) is
  'Manually officialize a proposed fine. §14 step 5c-ii: reads host_id from resources.metadata (was events.host_id) and updates fine_review_periods by resource_id (was event_id).';

-- =============================================================================
-- 8. issue_manual_fine — drop the p_event_id parameter
-- =============================================================================
-- The dual p_event_id / p_resource_id arg pair existed because fines
-- itself had two columns. Now the column is gone, so the arg goes
-- with it. Swift FineRepository.issueManual passes both (keyword
-- args), so the old signature would still resolve — but Postgres
-- can't have two functions with overlapping defaulted arg lists
-- when both could match. Drop the old signature explicitly before
-- creating the new one.

drop function if exists public.issue_manual_fine(
  uuid,    -- p_group_id
  uuid,    -- p_user_id
  numeric, -- p_amount
  text,    -- p_reason
  uuid,    -- p_rule_id
  uuid,    -- p_event_id
  uuid     -- p_resource_id
);

create or replace function public.issue_manual_fine(
  p_group_id    uuid,
  p_user_id     uuid,
  p_amount      numeric,
  p_reason      text,
  p_rule_id     uuid,
  p_resource_id uuid default null
)
returns public.fines
language plpgsql
security definer
set search_path = public
as $$
declare
  f             public.fines;
  r             public.rules;
  v_snapshot    jsonb;
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
        'trigger',     coalesce(r.trigger, to_jsonb(r.conditions)),
        'action',      coalesce(r.action,  to_jsonb(r.consequences)),
        'rule_title',  coalesce(r.title,   r.name),
        'rule_slug',   r.slug
      );
    end if;
  end if;

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
    jsonb_build_object('fine_id', f.id, 'rule_id', f.rule_id, 'via', 'issue_manual_fine'),
    now(), now(), auth.uid()
  );

  return f;
end;
$$;

revoke execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) from public, anon;
grant  execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) to authenticated, service_role;

comment on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) is
  'Admin-issued ad-hoc fine. §14 step 5c-ii: collapsed p_event_id/p_resource_id args into the single p_resource_id; fines.event_id column dropped.';
