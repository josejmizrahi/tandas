-- 00031 rollback — Drop outbox dispatcher RPCs.
--
-- Tras este rollback, el dispatch-notifications edge function rompe
-- (depende de las 4 funciones). Solo aplicar si se reescribe el
-- dispatcher al patrón anterior con .from('notifications_outbox')
-- — y solo si PostgREST schema cache es confiable.

drop function if exists public.claim_pending_outbox(int);
drop function if exists public.mark_outbox_sent(uuid);
drop function if exists public.mark_outbox_failed(uuid, text);
drop function if exists public.mark_outbox_skipped(uuid, text);
