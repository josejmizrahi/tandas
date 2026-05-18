begin;
drop function if exists public.get_placeholder_history_summary(uuid);
drop function if exists public.discover_pending_placeholders();
commit;
