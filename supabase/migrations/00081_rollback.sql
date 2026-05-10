-- 00081 rollback — Restore the pre-BigBang trigger body that reads
-- groups.no_show_grace_minutes. WILL FAIL at trigger fire time if 00078
-- is still in effect (column does not exist). Only walk back this
-- migration alongside a rollback of 00078.

create or replace function public.set_auto_no_show_at()
returns trigger language plpgsql set search_path = public as $$
declare g public.groups;
begin
  select * into g from public.groups where id = new.group_id;
  new.auto_no_show_at := new.starts_at + (g.no_show_grace_minutes || ' minutes')::interval;
  return new;
end;
$$;
