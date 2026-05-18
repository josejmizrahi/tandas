begin;
drop function if exists public.decline_placeholder_claim(text);
drop function if exists public.accept_placeholder_claim(text, uuid);
commit;
