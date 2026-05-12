-- Rollback for 00026_archive_rule_on_repeal_pass.sql

drop trigger if exists archive_rule_on_repeal_pass on public.votes;
drop function if exists public.archive_rule_on_repeal_pass();
