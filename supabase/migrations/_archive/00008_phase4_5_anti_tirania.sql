-- Phase 4.5: Anti-tiranía
--
-- New group columns:
--   grace_period_events  : new members are exempt from auto-fines for their
--                          first N events (default 3). Counted from joined_at,
--                          based on attendance rows that already exist.
--   monthly_fine_cap_mxn : per-user cap on auto-generated fines per calendar
--                          month. NULL = no cap (default).
--
-- New fines column:
--   rule_snapshot : jsonb capture of the rule's trigger+action at the moment
--                   the fine was issued. Lets appeals reference the rule
--                   version that existed when the fine was assigned, not the
--                   current (possibly modified) one.
--
-- evaluate_event_rules update:
--   - Honors grace_period_events (count attendance with arrived_at OR
--     no_show=true OR cancelled_same_day for the user before this event).
--   - Honors monthly_fine_cap_mxn (sum auto fines this month for the user;
--     skip if next fine would exceed the cap).
--   - Records rule_snapshot for every fine.
--
-- issue_manual_fine update:
--   - Records rule_snapshot from the rule (or null if rule_id is null).
--
-- close_vote update:
--   - Handles subject_type='amnesty' → waives ALL unpaid+unwaived fines in
--     the group at the moment the amnesty passes.
--   - Adds 'amnesty' to votes.subject_type CHECK constraint.

-- =========================================================
-- Group columns
-- =========================================================
alter table public.groups
  add column if not exists grace_period_events int not null default 3
    check (grace_period_events >= 0 and grace_period_events <= 50),
  add column if not exists monthly_fine_cap_mxn numeric(12,2)
    check (monthly_fine_cap_mxn is null or monthly_fine_cap_mxn >= 0);

-- =========================================================
-- Fines column
-- =========================================================
alter table public.fines
  add column if not exists rule_snapshot jsonb;

-- =========================================================
-- votes.subject_type: add 'amnesty'
-- =========================================================
alter table public.votes
  drop constraint if exists votes_subject_type_check;
alter table public.votes
  add constraint votes_subject_type_check
  check (subject_type in ('rule_proposal','rule_repeal','fine_appeal','host_swap','general','amnesty'));

-- =========================================================
-- evaluate_event_rules — grace + cap + snapshot
-- =========================================================
create or replace function public.evaluate_event_rules(p_event_id uuid)
returns int
language plpgsql security definer set search_path = public as $$
declare
  e public.events; g public.groups; r public.rules; att public.event_attendance;
  v_count int := 0; v_excepted boolean;
  v_minutes_late numeric; v_threshold timestamptz; v_step_count int;
  v_amount numeric; v_max numeric; v_step_min int; v_step_inc numeric; v_base numeric; v_deadline timestamptz;
  v_member_events int;
  v_month_total numeric;
begin
  select * into e from public.events where id = p_event_id;
  if not found then raise exception 'event not found'; end if;
  if not public.is_group_admin(e.group_id, auth.uid()) then raise exception 'admin only'; end if;
  select * into g from public.groups where id = e.group_id;

  for r in select * from public.rules where group_id = e.group_id and enabled and status = 'active' loop
    for att in select * from public.event_attendance where event_id = e.id loop

      -- Grace period: skip if member has fewer than grace_period_events
      -- in their history (counts only events where they "showed up" in some
      -- way: arrived, no-show, or same-day-cancel — pure pending RSVPs don't count)
      if g.grace_period_events > 0 then
        select count(*) into v_member_events
        from public.event_attendance ea
        join public.events ev on ev.id = ea.event_id
        where ea.user_id = att.user_id
          and ev.group_id = e.group_id
          and ev.id <> e.id
          and ev.starts_at < e.starts_at
          and (ea.arrived_at is not null or ea.no_show or ea.cancelled_same_day);
        if v_member_events < g.grace_period_events then
          continue;
        end if;
      end if;

      -- Per-rule exception list
      v_excepted := exists (
        select 1 from jsonb_array_elements(r.exceptions) ex
        where (ex->>'user_id')::uuid = att.user_id
      );
      if v_excepted then continue; end if;

      -- Idempotency: skip if a fine already exists for this (event, rule, user)
      if exists (select 1 from public.fines where event_id = e.id and rule_id = r.id and user_id = att.user_id) then
        continue;
      end if;

      case r.trigger->>'type'

      when 'late_arrival' then
        if att.arrived_at is null then continue; end if;
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

      when 'no_confirmation' then
        v_deadline := coalesce(e.rsvp_deadline,
          e.starts_at - make_interval(hours => coalesce((r.trigger->'params'->>'deadline_offset_hours')::int, 24)));
        if att.rsvp_at is not null and att.rsvp_at <= v_deadline then continue; end if;
        if not (att.rsvp_status = 'pending' or att.rsvp_at is null or att.rsvp_at > v_deadline) then continue; end if;
        v_amount := coalesce((r.trigger->'params'->>'fixed_amount')::numeric, (r.action->'params'->>'amount')::numeric, 0);

      when 'same_day_cancel' then
        if not att.cancelled_same_day then continue; end if;
        v_amount := coalesce((r.trigger->'params'->>'fixed_amount')::numeric, (r.action->'params'->>'amount')::numeric, 0);

      when 'no_show' then
        if not att.no_show then continue; end if;
        if att.rsvp_status = 'declined' then continue; end if;
        v_amount := coalesce((r.trigger->'params'->>'fixed_amount')::numeric, (r.action->'params'->>'amount')::numeric, 0);

      else
        continue; -- manual / host_skip / host_food_late: applied manually
      end case;

      -- Monthly cap: skip if this fine would push user over the cap
      if g.monthly_fine_cap_mxn is not null then
        select coalesce(sum(amount), 0) into v_month_total
        from public.fines
        where group_id = e.group_id
          and user_id = att.user_id
          and auto_generated = true
          and date_trunc('month', created_at) = date_trunc('month', now());
        if v_month_total + v_amount > g.monthly_fine_cap_mxn then
          continue;
        end if;
      end if;

      insert into public.fines (
        group_id, user_id, rule_id, event_id, reason, amount,
        auto_generated, issued_by, details, rule_snapshot
      )
      values (
        e.group_id, att.user_id, r.id, e.id,
        case r.trigger->>'type'
          when 'late_arrival' then format('Llegada tarde — %s', r.title)
          when 'no_confirmation' then format('No confirmó a tiempo — %s', r.title)
          when 'same_day_cancel' then format('Canceló el mismo día — %s', r.title)
          when 'no_show' then format('No-show — %s', r.title)
          else r.title
        end,
        v_amount, true, auth.uid(),
        case r.trigger->>'type'
          when 'late_arrival' then jsonb_build_object('minutes_late', round(v_minutes_late)::int, 'tier_count', v_step_count)
          else null
        end,
        jsonb_build_object('trigger', r.trigger, 'action', r.action, 'rule_title', r.title)
      );
      v_count := v_count + 1;
    end loop;
  end loop;

  update public.events set rules_evaluated_at = now(), status = 'completed' where id = e.id;
  return v_count;
end;
$$;
revoke execute on function public.evaluate_event_rules(uuid) from public, anon;
grant  execute on function public.evaluate_event_rules(uuid) to authenticated;

-- =========================================================
-- issue_manual_fine — record snapshot from rule (if any)
-- =========================================================
create or replace function public.issue_manual_fine(
  p_group_id uuid,
  p_user_id uuid,
  p_amount numeric,
  p_reason text,
  p_rule_id uuid,
  p_event_id uuid
)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f public.fines;
  r public.rules;
  v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  if not public.is_group_member(p_group_id, p_user_id) then raise exception 'target user not a member'; end if;
  if p_amount < 0 then raise exception 'amount must be non-negative'; end if;
  if length(coalesce(p_reason, '')) < 2 then raise exception 'reason required'; end if;

  if p_rule_id is not null then
    select * into r from public.rules where id = p_rule_id;
    if found then
      v_snapshot := jsonb_build_object('trigger', r.trigger, 'action', r.action, 'rule_title', r.title);
    end if;
  end if;

  insert into public.fines (
    group_id, user_id, amount, reason, rule_id, event_id,
    auto_generated, issued_by, rule_snapshot
  )
  values (
    p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_event_id,
    false, auth.uid(), v_snapshot
  )
  returning * into f;
  return f;
end;
$$;
revoke execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) from public, anon;
grant  execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) to authenticated;

-- =========================================================
-- close_vote — handle amnesty (waive all unpaid fines in group)
-- =========================================================
create or replace function public.close_vote(p_vote_id uuid)
returns public.votes language plpgsql security definer set search_path = public as $$
declare
  v public.votes;
  yes int; no int; abstain int; total int; eligible int;
  pass boolean; new_status text;
begin
  select * into v from public.votes where id = p_vote_id;
  if not found then raise exception 'vote not found'; end if;
  if not public.is_group_admin(v.group_id, auth.uid()) and v.closes_at > now() then
    raise exception 'vote still open';
  end if;
  if v.status <> 'open' then return v; end if;

  select count(*) filter (where choice='yes'), count(*) filter (where choice='no'),
         count(*) filter (where choice='abstain'), count(*)
    into yes, no, abstain, total
  from public.vote_ballots where vote_id = v.id;

  if v.committee_only then
    select count(*) into eligible from public.group_members where group_id = v.group_id and active and on_committee;
  else
    select count(*) into eligible from public.group_members where group_id = v.group_id and active;
  end if;

  pass := (eligible = 0)
       or ((total::numeric / nullif(eligible,0) >= v.quorum)
           and ((yes::numeric / nullif(yes + no, 0)) >= v.threshold));
  new_status := case when pass then 'passed' else 'rejected' end;

  update public.votes set status = new_status,
    result = jsonb_build_object('yes', yes, 'no', no, 'abstain', abstain, 'total', total, 'eligible', eligible)
  where id = v.id returning * into v;

  if new_status = 'passed' then
    if v.subject_type = 'rule_proposal' and v.subject_id is not null then
      update public.rules set status='active', enabled=true where id = v.subject_id;
    elsif v.subject_type = 'rule_repeal' and v.subject_id is not null then
      update public.rules set status='archived', enabled=false where id = v.subject_id;
    elsif v.subject_type = 'fine_appeal' and v.subject_id is not null then
      update public.fines set waived=true, waived_at=now(), waived_reason='Apelación aprobada' where id = v.subject_id;
    elsif v.subject_type = 'amnesty' then
      -- Waive ALL unpaid + unwaived fines in the group at this moment
      update public.fines
        set waived=true, waived_at=now(), waived_reason='Amnistía general'
        where group_id = v.group_id and paid = false and waived = false;
    end if;
  end if;
  return v;
end;
$$;
revoke execute on function public.close_vote(uuid) from public, anon;
grant  execute on function public.close_vote(uuid) to authenticated;
