-- Expose owed_to_membership_id in member_obligation_summary so iOS can
-- pre-fill the recipient when settling member-to-member. The data
-- already flows through the underlying join; the read RPC just wasn't
-- projecting it. Additive change — existing callers keep working
-- (positional UNNEST in PostgREST is by column name).
--
-- Postgres requires drop+recreate when RETURNS TABLE shape changes.

drop function if exists public.member_obligation_summary(uuid, uuid);

create function public.member_obligation_summary(
  p_group_id      uuid,
  p_membership_id uuid
)
returns table(
  obligation_id          uuid,
  kind                   text,
  amount_outstanding     numeric,
  owed_to_kind           text,
  owed_to_membership_id  uuid,
  owed_to_label          text
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select o.id,
         o.obligation_kind,
         o.amount_outstanding,
         o.owed_to_kind,
         o.owed_to_membership_id,
         coalesce(p.display_name, p.username, o.owed_to_kind)
  from public.group_obligations o
  left join public.group_memberships m on m.id = o.owed_to_membership_id
  left join public.profiles p on p.id = m.user_id
  where o.group_id = p_group_id
    and o.owed_by_membership_id = p_membership_id
    and o.status in ('open','partially_settled')
  order by o.created_at;
$$;
