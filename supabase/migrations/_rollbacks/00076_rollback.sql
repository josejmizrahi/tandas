-- 00076 rollback — Clear backfilled module_key annotations.
--
-- Reverses 00076 by setting module_key to null on every rule that
-- currently has it set. Note: this also clears module_key annotations
-- written by seed_module_rules after the backfill ran — making this
-- rollback unsafe to run in isolation. Pair with rollback of 00074
-- (cascade) and 00073 (seed/archive RPCs) so the system is consistent.

update public.rules
   set module_key = null,
       updated_at = now()
 where module_key is not null;
