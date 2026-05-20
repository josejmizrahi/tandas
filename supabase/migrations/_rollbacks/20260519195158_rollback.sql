-- Rollback for 20260519195158_drop_legacy_issue_manual_fine_overload.sql.
-- Recreates the 6-arg overload of issue_manual_fine that delegates to
-- the 7-arg V1-03 version with p_client_id=null. Leaves the system in
-- two-overload limbo — coordinate with mig 00353's rollback.

create or replace function public.issue_manual_fine(
  p_group_id    uuid,
  p_user_id     uuid,
  p_amount      numeric,
  p_reason      text,
  p_rule_id     uuid default null,
  p_resource_id uuid default null
)
returns public.fines
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  f public.fines;
begin
  f := public.issue_manual_fine(
    p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_resource_id, null
  );
  return f;
end;
$$;
