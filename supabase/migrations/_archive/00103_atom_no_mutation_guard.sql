-- 00103 — Atom append-only guard.
--
-- Audit task M.2. Plans/Active/AtomProjection.md § "Trigger anti-mutation"
-- documents the pattern; this migration applies it to the two
-- fully-immutable atom tables landed in 00078.
--
-- Tables covered:
--   - public.ledger_entries  — money atoms; every monetary movement is a
--     new row (corrections land as reversal entries, never edits).
--   - public.rsvp_actions    — RSVP atoms; each status change is a new
--     row, never an edit.
--
-- Tables intentionally NOT covered yet (have legitimate mutation paths):
--   - public.system_events   — processed_at is set by the cron after the
--     rule engine consumes the row. A partial guard that allows the
--     processed_at update is on the roadmap once the cron path stabilises.
--   - public.vote_casts      — choice/cast_at/updated_at are mutable while
--     the parent vote is open (members may recast before close). Needs a
--     guard that joins votes.status; deferred until Phase 5.
--
-- Both excluded tables are still atom-shaped (append-only id and created
-- timestamp); the guard for them is a separate task.

create or replace function public.atom_no_mutation_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception
      'atom row %.% is append-only; UPDATE rejected',
      tg_table_schema, tg_table_name
      using errcode = 'check_violation';
  end if;
  if tg_op = 'DELETE' then
    raise exception
      'atom row %.% is append-only; DELETE rejected',
      tg_table_schema, tg_table_name
      using errcode = 'check_violation';
  end if;
  return null;
end $$;

comment on function public.atom_no_mutation_guard() is
  'Append-only enforcement for Atom tables. Attach via BEFORE UPDATE OR DELETE trigger. See Plans/Active/AtomProjection.md.';

drop trigger if exists ledger_entries_atom_guard on public.ledger_entries;
create trigger ledger_entries_atom_guard
  before update or delete on public.ledger_entries
  for each row execute function public.atom_no_mutation_guard();

drop trigger if exists rsvp_actions_atom_guard on public.rsvp_actions;
create trigger rsvp_actions_atom_guard
  before update or delete on public.rsvp_actions
  for each row execute function public.atom_no_mutation_guard();
