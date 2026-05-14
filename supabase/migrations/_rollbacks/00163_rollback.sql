-- Rollback for 00163_vote_casts_append_only.sql
--
-- Restores the pre-refactor mutable shape: UNIQUE constraint, AFTER
-- UPDATE resolve trigger, UPDATE-based cast_vote, simple aggregation
-- in vote_counts_view and finalize_vote. Use only if the append-only
-- pattern proves incompatible with a downstream surface we missed.
--
-- Re-applying the prior migrations 00020/00032/00123/00148/00150
-- in order restores the SQL functions. Run this rollback first to
-- remove the new trigger/guard, then re-run those migrations.

drop trigger if exists vote_casts_atom_guard on public.vote_casts;
drop trigger if exists vote_casts_resolve_user_action on public.vote_casts;

-- Restore the unique constraint (assumes vote_casts has at most one
-- row per (vote_id, member_id) at rollback time — caller must validate).
alter table public.vote_casts
  add constraint vote_casts_vote_id_member_id_key unique (vote_id, member_id);

-- Re-create the set_updated_at trigger on UPDATE.
drop trigger if exists vote_casts_set_updated_at on public.vote_casts;
create trigger vote_casts_set_updated_at
  before update on public.vote_casts
  for each row execute function public.set_updated_at();

-- Re-apply mig 00043 + 00020 + 00138 + 00150 to restore the mutable
-- function bodies. (Manual step; pasted here as reference.)
