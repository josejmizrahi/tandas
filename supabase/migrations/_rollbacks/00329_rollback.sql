-- 00329 rollback — drop the batch helper. Reapply the pre-00329 edge fn
-- shape (separate atom-emit + status UPDATE) to avoid leaving callers
-- pointing at a missing function.

drop function if exists public.mark_slots_expired_batch(uuid[]);
