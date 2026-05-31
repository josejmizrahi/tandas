-- 00081 — Fix set_auto_no_show_at trigger function for post-BigBang.
--
-- The trigger on events.starts_at insert/update reads
-- `g.no_show_grace_minutes` which was dropped by mig 00078. Every event
-- creation through the new wizard fails with "record g has no field
-- no_show_grace_minutes".
--
-- Post BigBang the grace minutes belongs to the basic_fines module
-- config. For now default to 60 minutes (the previous column default)
-- so events still get an auto_no_show_at value. Phase 3 (Money) will
-- thread the real config via modules.config jsonb.

create or replace function public.set_auto_no_show_at()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_grace_minutes int := 60;
begin
  -- Post BigBang: groups.no_show_grace_minutes column was dropped. Use
  -- a sensible fallback. When the basic_fines module gains a config
  -- jsonb (Phase 3), read from there.
  new.auto_no_show_at := new.starts_at + (v_grace_minutes || ' minutes')::interval;
  return new;
end;
$$;

comment on function public.set_auto_no_show_at() is
  'Trigger fn that stamps events.auto_no_show_at = starts_at + grace minutes. Post mig 00081: hardcoded 60-min default (groups.no_show_grace_minutes dropped by BigBang). Phase 3 reads module config.';
