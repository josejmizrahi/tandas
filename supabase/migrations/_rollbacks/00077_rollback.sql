-- Rollback for 00077: restore the V1 unconditional insert.
-- Note: rolling back will break Phase 2 slot-expired fines again — only do this
-- if there's a regression in the V1 dinner flow.

create or replace function public.on_fine_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_user_id uuid;
begin
  if new.auto_generated and new.status = 'proposed' then
    insert into public.fine_review_periods (event_id, expires_at)
    values (new.event_id, now() + interval '24 hours')
    on conflict (event_id) do nothing;

    select host_id into v_host_user_id from public.events where id = new.event_id;
    if v_host_user_id is not null then
      insert into public.user_actions (
        user_id, group_id, action_type, reference_id,
        title, body, priority
      ) values (
        v_host_user_id, new.group_id, 'fineProposalReview', new.event_id,
        'Revisa multas propuestas',
        'Las multas se oficializan en 24 horas si no las revisas',
        'high'
      ) on conflict do nothing;
    end if;
  end if;
  return new;
end;
$$;
