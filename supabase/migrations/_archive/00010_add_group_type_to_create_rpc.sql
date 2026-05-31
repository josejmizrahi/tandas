-- Phase 1 iOS: extend create_group_with_admin to accept group_type.
-- The column was added in 00009 with default 'recurring_dinner', but the RPC
-- was never updated, so creating a group via the iOS app couldn't set the type.

drop function if exists public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean
);

create or replace function public.create_group_with_admin(
  p_name text,
  p_description text,
  p_event_label text,
  p_currency text,
  p_timezone text,
  p_default_day int,
  p_default_time time,
  p_default_location text,
  p_voting_threshold numeric,
  p_voting_quorum numeric,
  p_fund_enabled boolean,
  p_group_type text
)
returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  insert into public.groups (
    name, description, created_by, event_label, currency, timezone,
    default_day_of_week, default_start_time, default_location,
    voting_threshold, voting_quorum, fund_enabled, group_type
  ) values (
    p_name, p_description, auth.uid(),
    coalesce(p_event_label, 'Tanda'),
    coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    p_default_day, p_default_time, p_default_location,
    coalesce(p_voting_threshold, 0.5),
    coalesce(p_voting_quorum, 0.5),
    coalesce(p_fund_enabled, true),
    coalesce(p_group_type, 'recurring_dinner')
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, turn_order, on_committee)
  values (g.id, auth.uid(), 'admin', 1, true);
  return g;
end;
$$;

revoke execute on function public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean, text
) from public, anon;

grant execute on function public.create_group_with_admin(
  text, text, text, text, text, int, time, text, numeric, numeric, boolean, text
) to authenticated;
