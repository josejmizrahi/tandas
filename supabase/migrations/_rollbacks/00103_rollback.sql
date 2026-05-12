-- Rollback for 00103 — drops the append-only triggers and guard function.

drop trigger if exists ledger_entries_atom_guard on public.ledger_entries;
drop trigger if exists rsvp_actions_atom_guard  on public.rsvp_actions;
drop function if exists public.atom_no_mutation_guard();
