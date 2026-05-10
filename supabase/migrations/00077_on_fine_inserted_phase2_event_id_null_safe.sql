-- 00071 — Make on_fine_inserted() Phase 2 safe.
--
-- V1 trigger unconditionally inserted into fine_review_periods (event_id NOT NULL)
-- and looked up events.host_id. With Phase 2 polymorphic fines (slots, etc.)
-- new.event_id is null and these inserts fail, blocking the rule engine
-- from materializing slot-expired fines.
--
-- Fix: gate both writes on `new.event_id is not null`. The 24h grace review
-- period is a V1 dinner-host UX; Phase 2 slot-expired fines don't need it
-- (the holder of an expired-without-booking cupo doesn't get a re-check window).
-- Forward-compatible: behavior unchanged for V1 events (event_id always set).

create or replace function public.on_fine_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_user_id uuid;
begin
  if new.auto_generated and new.status = 'proposed' and new.event_id is not null then
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
