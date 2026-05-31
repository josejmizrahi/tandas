-- Phase 1 Foundation patches.
--
-- 4 bug fixes applied on top of the bootstrap schema (00001-00003):
--   1. handle_new_user: support phone-only signups (email may be NULL)
--   2. vote_ballots policies: lock update/delete when vote.status != 'open'
--   3. set_turn_order: ignore inactive members when nulling turn_order
--   4. evaluate_event_rules late_arrival: use g.timezone explicitly (was session TZ)
--
-- 5 structural additions for Phase 2+ recurrence and no-show automation:
--   - events.parent_event_id (linaje recurrencias)
--   - events.auto_no_show_at (computed)
--   - groups.no_show_grace_minutes (configurable grace period)
--   - expense_shares.percentage (auditable for split_type='percentage')
--   - set_auto_no_show_at trigger

-- =========================================================
-- Bug fix #1: handle_new_user supports phone-only signups
-- =========================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'display_name',
      nullif(split_part(new.email, '@', 1), ''),
      'Usuario'
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- =========================================================
-- Bug fix #2: vote_ballots locked once vote is no longer open
-- =========================================================
drop policy if exists "ballots_update_self" on public.vote_ballots;
drop policy if exists "ballots_delete_self" on public.vote_ballots;

create policy "ballots_update_self" on public.vote_ballots for update to authenticated
using (
  user_id = auth.uid()
  and exists (select 1 from public.votes v where v.id = vote_id and v.status = 'open')
)
with check (user_id = auth.uid());

create policy "ballots_delete_self" on public.vote_ballots for delete to authenticated
using (
  user_id = auth.uid()
  and exists (select 1 from public.votes v where v.id = vote_id and v.status = 'open')
);

-- =========================================================
-- Bug fix #3: set_turn_order ignores inactive members
-- =========================================================
create or replace function public.set_turn_order(p_group_id uuid, p_user_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  -- Only clear turn_order for active members; inactive ones keep their historical order
  update public.group_members set turn_order = null
    where group_id = p_group_id and active;
  for i in 1..array_length(p_user_ids, 1) loop
    update public.group_members set turn_order = i
      where group_id = p_group_id and user_id = p_user_ids[i] and active;
  end loop;
end;
$$;
revoke execute on function public.set_turn_order(uuid, uuid[]) from public, anon;
grant  execute on function public.set_turn_order(uuid, uuid[]) to authenticated;

-- =========================================================
-- Bug fix #4: evaluate_event_rules late_arrival uses g.timezone explicitly
-- (full function rewrite — same logic as bootstrap, only late_arrival branch changes)
-- =========================================================
create or replace function public.evaluate_event_rules(p_event_id uuid)
returns int
language plpgsql security definer set search_path = public as $$
declare
  e public.events; g public.groups; r public.rules; att public.event_attendance;
  v_count int := 0; v_excepted boolean;
  v_minutes_late numeric; v_threshold timestamptz; v_step_count int;
  v_amount numeric; v_max numeric; v_step_min int; v_step_inc numeric; v_base numeric; v_deadline timestamptz;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not public.is_group_admin(e.group_id, auth.uid()) then raise exception 'admin only'; end if;
  select * into g from public.groups where id = e.group_id;

  for r in select * from public.rules where group_id = e.group_id and enabled and status = 'active' loop
    for att in select * from public.event_attendance where event_id = e.id loop
      v_excepted := exists (
        select 1 from jsonb_array_elements(r.exceptions) ex
        where (ex->>'user_id')::uuid = att.user_id
      );
      if v_excepted then continue; end if;
      if exists (select 1 from public.fines where event_id = e.id and rule_id = r.id and user_id = att.user_id) then
        continue;
      end if;

      case r.trigger->>'type'

      when 'late_arrival' then
        if att.arrived_at is null then continue; end if;
        -- FIXED: use g.timezone explicitly instead of session TZ
        if (r.trigger->'params'->>'start_threshold_time') is not null then
          v_threshold := (
            date_trunc('day', e.starts_at at time zone g.timezone)
            + (r.trigger->'params'->>'start_threshold_time')::interval
          ) at time zone g.timezone;
        else
          v_threshold := e.starts_at;
        end if;
        if att.arrived_at <= v_threshold then continue; end if;
        v_minutes_late := extract(epoch from (att.arrived_at - v_threshold)) / 60.0;
        v_base    := coalesce((r.trigger->'params'->>'base_amount')::numeric,    (r.action->'params'->>'amount')::numeric, 0);
        v_step_min:= coalesce((r.trigger->'params'->>'step_minutes')::int,       30);
        v_step_inc:= coalesce((r.trigger->'params'->>'step_increment')::numeric, 0);
        v_max     := nullif(r.trigger->'params'->>'max_amount','')::numeric;
        v_step_count := floor(v_minutes_late::numeric / v_step_min);
        v_amount := v_base + (v_step_count * v_step_inc);
        if v_max is not null and v_amount > v_max then v_amount := v_max; end if;

        insert into public.fines (group_id, user_id, rule_id, event_id, reason, amount, auto_generated, issued_by, details)
        values (
          e.group_id, att.user_id, r.id, e.id,
          format('Llegada tarde (%s min) — %s', round(v_minutes_late)::int, r.title),
          v_amount, true, auth.uid(),
          jsonb_build_object('minutes_late', round(v_minutes_late)::int, 'tier_count', v_step_count)
        );
        v_count := v_count + 1;

      when 'no_confirmation' then
        v_deadline := coalesce(e.rsvp_deadline,
          e.starts_at - make_interval(hours => coalesce((r.trigger->'params'->>'deadline_offset_hours')::int, 24)));
        if att.rsvp_at is not null and att.rsvp_at <= v_deadline then continue; end if;
        if att.rsvp_status = 'pending' or att.rsvp_at is null or att.rsvp_at > v_deadline then
          v_amount := coalesce((r.trigger->'params'->>'fixed_amount')::numeric, (r.action->'params'->>'amount')::numeric, 0);
          insert into public.fines (group_id, user_id, rule_id, event_id, reason, amount, auto_generated, issued_by)
          values (e.group_id, att.user_id, r.id, e.id, format('No confirmó a tiempo — %s', r.title),
                  v_amount, true, auth.uid());
          v_count := v_count + 1;
        end if;

      when 'same_day_cancel' then
        if not att.cancelled_same_day then continue; end if;
        v_amount := coalesce((r.trigger->'params'->>'fixed_amount')::numeric, (r.action->'params'->>'amount')::numeric, 0);
        insert into public.fines (group_id, user_id, rule_id, event_id, reason, amount, auto_generated, issued_by)
        values (e.group_id, att.user_id, r.id, e.id, format('Canceló el mismo día — %s', r.title),
                v_amount, true, auth.uid());
        v_count := v_count + 1;

      when 'no_show' then
        if not att.no_show then continue; end if;
        if att.rsvp_status = 'declined' then continue; end if;
        v_amount := coalesce((r.trigger->'params'->>'fixed_amount')::numeric, (r.action->'params'->>'amount')::numeric, 0);
        insert into public.fines (group_id, user_id, rule_id, event_id, reason, amount, auto_generated, issued_by)
        values (e.group_id, att.user_id, r.id, e.id, format('No-show — %s', r.title),
                v_amount, true, auth.uid());
        v_count := v_count + 1;

      else
        null; -- manual / host_skip / host_food_late: applied manually
      end case;
    end loop;
  end loop;

  update public.events set rules_evaluated_at = now(), status = 'completed' where id = e.id;
  return v_count;
end;
$$;
revoke execute on function public.evaluate_event_rules(uuid) from public, anon;
grant  execute on function public.evaluate_event_rules(uuid) to authenticated;

-- =========================================================
-- Structural: recurrence + no-show automation
-- =========================================================

alter table public.events
  add column if not exists parent_event_id uuid references public.events(id) on delete set null,
  add column if not exists auto_no_show_at timestamptz;

create index if not exists idx_events_parent on public.events(parent_event_id) where parent_event_id is not null;
create index if not exists idx_events_auto_no_show on public.events(auto_no_show_at) where auto_no_show_at is not null;

alter table public.groups
  add column if not exists no_show_grace_minutes int not null default 60
  check (no_show_grace_minutes between 5 and 720);

alter table public.expense_shares
  add column if not exists percentage numeric(5,2)
  check (percentage is null or (percentage >= 0 and percentage <= 100));

-- Trigger to compute auto_no_show_at when an event is created or its starts_at moves
create or replace function public.set_auto_no_show_at()
returns trigger language plpgsql set search_path = public as $$
declare g public.groups;
begin
  select * into g from public.groups where id = new.group_id;
  new.auto_no_show_at := new.starts_at + (g.no_show_grace_minutes || ' minutes')::interval;
  return new;
end;
$$;

drop trigger if exists events_set_auto_no_show_at on public.events;
create trigger events_set_auto_no_show_at
before insert or update of starts_at on public.events
for each row execute function public.set_auto_no_show_at();
