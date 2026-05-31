-- 00162 — system_events partial atom guard (Constitution §7 enforcement).
--
-- Why
-- ===
-- Constitution Article 7: "Atoms son la única verdad histórica. Append-only,
-- sin UPDATE/DELETE, protegidos por trigger *_atom_guard. Atoms canónicos:
-- system_events, ledger_entries, rsvp_actions, vote_casts."
--
-- The original atom_no_mutation_guard rollout (mig 00103) explicitly
-- deferred system_events because the rule engine cron mutates
-- `processed_at` after consuming each event:
--
--   supabase/functions/process-system-events/index.ts:113-117
--     const update: Record<string, unknown> = { processed_at: now.toISOString() };
--     await supabase.from("system_events").update(update).eq("id", eventId);
--
-- That's a legitimate one-way state transition (null → timestamp); the
-- business columns (group_id, event_type, resource_id, member_id, payload,
-- occurred_at) must never change. This migration adds the partial guard
-- the original rollout marked as "on the roadmap once the cron path
-- stabilises" — the cron has been running in prod since v1 and is the
-- only writer that touches `processed_at`.
--
-- What
-- ====
-- A custom BEFORE UPDATE OR DELETE trigger function that:
--   - rejects every DELETE outright,
--   - rejects every UPDATE except the one-way `processed_at: null → ts`
--     transition with all other columns unchanged.
--
-- The comparison uses `to_jsonb(...) - 'processed_at'` so that any column
-- added in the future is automatically protected — the guard fails closed.
--
-- Cost
-- ====
-- One per-row check on each UPDATE / DELETE of system_events. The cron's
-- update loop already pays a per-row roundtrip, so the overhead is
-- negligible. INSERT is untouched.
--
-- Rollback
-- ========
-- _rollbacks/00162_rollback.sql

create or replace function public.system_events_processed_at_only_guard()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb;
  v_new jsonb;
begin
  if tg_op = 'DELETE' then
    raise exception
      'atom row %.% is append-only; DELETE rejected',
      tg_table_schema, tg_table_name
      using errcode = 'check_violation';
  end if;

  if tg_op = 'UPDATE' then
    -- The cron is allowed to stamp processed_at exactly once (null → ts).
    -- Resetting processed_at back to null, or shifting to a different
    -- timestamp, is rejected.
    if old.processed_at is not null then
      raise exception
        'system_events.processed_at is set-once; UPDATE rejected (id=%)',
        new.id
        using errcode = 'check_violation';
    end if;

    -- Strip processed_at from both rows and compare the remainder. If
    -- anything else differs, the UPDATE is mutating business state and
    -- must be rejected. Fails closed for any future column added to
    -- system_events: if it's not on the allow-list (just processed_at),
    -- the guard catches it.
    v_old := to_jsonb(old) - 'processed_at';
    v_new := to_jsonb(new) - 'processed_at';
    if v_old is distinct from v_new then
      raise exception
        'atom row %.% is append-only; only processed_at may transition (id=%)',
        tg_table_schema, tg_table_name, new.id
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end$$;

comment on function public.system_events_processed_at_only_guard() is
  'Append-only guard for system_events that allows the single legitimate mutation: processed_at transitioning null → timestamp by the rule-engine cron (process-system-events). Rejects DELETE and any other column change. Constitution §7.';

drop trigger if exists system_events_atom_guard on public.system_events;
create trigger system_events_atom_guard
  before update or delete on public.system_events
  for each row execute function public.system_events_processed_at_only_guard();
