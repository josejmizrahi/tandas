-- =========================================================
-- RPCs: groups · membership · rule engine · votes · pots · expenses
-- =========================================================

create or replace function public.create_group_with_admin(
  p_name text, p_description text, p_event_label text, p_currency text, p_timezone text,
  p_default_day int, p_default_time time, p_default_location text,
  p_voting_threshold numeric, p_voting_quorum numeric, p_fund_enabled boolean
)
returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  insert into public.groups (
    name, description, created_by, event_label, currency, timezone,
    default_day_of_week, default_start_time, default_location,
    voting_threshold, voting_quorum, fund_enabled
  ) values (
    p_name, p_description, auth.uid(),
    coalesce(p_event_label, 'Tanda'), coalesce(p_currency, 'MXN'),
    coalesce(p_timezone, 'America/Mexico_City'),
    p_default_day, p_default_time, p_default_location,
    coalesce(p_voting_threshold, 0.5), coalesce(p_voting_quorum, 0.5), coalesce(p_fund_enabled, true)
  ) returning * into g;

  insert into public.group_members (group_id, user_id, role, turn_order, on_committee)
  values (g.id, auth.uid(), 'admin', 1, true);
  return g;
end;
$$;
revoke execute on function public.create_group_with_admin(text,text,text,text,text,int,time,text,numeric,numeric,boolean) from public, anon;
grant  execute on function public.create_group_with_admin(text,text,text,text,text,int,time,text,numeric,numeric,boolean) to authenticated;

create or replace function public.join_group_by_code(p_code text)
returns public.groups
language plpgsql security definer set search_path = public as $$
declare g public.groups; v_max int;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  select * into g from public.groups where invite_code = p_code;
  if not found then raise exception 'invite code not found'; end if;

  if exists (select 1 from public.group_members where group_id = g.id and user_id = auth.uid()) then
    update public.group_members set active = true where group_id = g.id and user_id = auth.uid();
    return g;
  end if;

  select coalesce(max(turn_order), 0) into v_max from public.group_members where group_id = g.id;
  insert into public.group_members (group_id, user_id, role, turn_order)
  values (g.id, auth.uid(), 'member', v_max + 1);
  return g;
end;
$$;
revoke execute on function public.join_group_by_code(text) from public, anon;
grant  execute on function public.join_group_by_code(text) to authenticated;

create or replace function public.set_turn_order(p_group_id uuid, p_user_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  update public.group_members set turn_order = null where group_id = p_group_id;
  for i in 1..array_length(p_user_ids, 1) loop
    update public.group_members set turn_order = i
      where group_id = p_group_id and user_id = p_user_ids[i];
  end loop;
end;
$$;
revoke execute on function public.set_turn_order(uuid, uuid[]) from public, anon;
grant  execute on function public.set_turn_order(uuid, uuid[]) to authenticated;

create or replace function public.next_host_for_group(p_group_id uuid, p_cycle int)
returns uuid language sql stable security definer set search_path = public as $$
  with ordered as (
    select user_id, row_number() over (order by turn_order nulls last, joined_at) as rn,
           count(*) over () as total
    from public.group_members
    where group_id = p_group_id and active and turn_order is not null
  )
  select user_id from ordered where rn = (((p_cycle - 1) % nullif(total,0)) + 1);
$$;

create or replace function public.create_event(
  p_group_id uuid, p_starts_at timestamptz, p_ends_at timestamptz,
  p_location text, p_title text, p_host_id uuid, p_cycle_number int, p_rsvp_deadline timestamptz
)
returns public.events
language plpgsql security definer set search_path = public as $$
declare e public.events; g public.groups; v_host uuid; v_cycle int;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then raise exception 'not a member'; end if;
  select * into g from public.groups where id = p_group_id;

  v_cycle := coalesce(p_cycle_number,
    (select coalesce(max(cycle_number), 0) + 1 from public.events where group_id = p_group_id));
  v_host := coalesce(p_host_id,
    case when g.rotation_enabled then public.next_host_for_group(p_group_id, v_cycle) else null end);

  insert into public.events (
    group_id, starts_at, ends_at, location, title, host_id, cycle_number,
    rsvp_deadline, created_by
  ) values (
    p_group_id, p_starts_at, p_ends_at,
    coalesce(p_location, g.default_location), p_title,
    v_host, v_cycle, p_rsvp_deadline, auth.uid()
  ) returning * into e;

  insert into public.event_attendance (event_id, user_id)
  select e.id, gm.user_id
  from public.group_members gm
  where gm.group_id = p_group_id and gm.active
  on conflict do nothing;

  return e;
end;
$$;
revoke execute on function public.create_event(uuid, timestamptz, timestamptz, text, text, uuid, int, timestamptz) from public, anon;
grant  execute on function public.create_event(uuid, timestamptz, timestamptz, text, text, uuid, int, timestamptz) to authenticated;

create or replace function public.check_in_attendee(p_event_id uuid, p_user_id uuid, p_arrived_at timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select group_id into g from public.events where id = p_event_id;
  if not (auth.uid() = p_user_id or public.is_group_admin(g, auth.uid())) then
    raise exception 'not allowed';
  end if;
  update public.event_attendance
    set arrived_at = coalesce(p_arrived_at, now()), marked_by = auth.uid()
  where event_id = p_event_id and user_id = p_user_id;
end;
$$;
revoke execute on function public.check_in_attendee(uuid, uuid, timestamptz) from public, anon;
grant  execute on function public.check_in_attendee(uuid, uuid, timestamptz) to authenticated;

-- Rule engine. Iterates active rules of the event's group and creates fines
-- per attendance row, skipping members listed in `rules.exceptions`.
-- Idempotent per (rule, event, user) via existence check.
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
        if (r.trigger->'params'->>'start_threshold_time') is not null then
          v_threshold := (e.starts_at::date::text || ' ' || (r.trigger->'params'->>'start_threshold_time'))::timestamptz;
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

create or replace function public.pay_fine(p_fine_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare f public.fines; g public.groups;
begin
  select * into f from public.fines where id = p_fine_id;
  if not found then raise exception 'fine not found'; end if;
  select * into g from public.groups where id = f.group_id;
  if not (f.user_id = auth.uid() or public.is_group_admin(f.group_id, auth.uid())) then
    raise exception 'not allowed';
  end if;
  if f.paid then return; end if;
  update public.fines set paid = true, paid_at = now(), paid_to_fund = g.fund_enabled where id = p_fine_id;
  if g.fund_enabled then
    update public.groups set fund_balance = fund_balance + f.amount where id = g.id;
  end if;
end;
$$;
revoke execute on function public.pay_fine(uuid) from public, anon;
grant  execute on function public.pay_fine(uuid) to authenticated;

create or replace function public.create_vote(
  p_group_id uuid, p_subject_type text, p_subject_id uuid,
  p_title text, p_description text, p_payload jsonb, p_committee_only boolean
)
returns public.votes language plpgsql security definer set search_path = public as $$
declare v public.votes; g public.groups;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then raise exception 'not a member'; end if;
  select * into g from public.groups where id = p_group_id;
  insert into public.votes (
    group_id, subject_type, subject_id, title, description, payload,
    created_by, closes_at, threshold, quorum, committee_only
  ) values (
    p_group_id, p_subject_type, p_subject_id, p_title, p_description, p_payload,
    auth.uid(), now() + make_interval(hours => g.vote_duration_hours),
    g.voting_threshold, g.voting_quorum, coalesce(p_committee_only, false)
  ) returning * into v;
  return v;
end;
$$;
revoke execute on function public.create_vote(uuid, text, uuid, text, text, jsonb, boolean) from public, anon;
grant  execute on function public.create_vote(uuid, text, uuid, text, text, jsonb, boolean) to authenticated;

create or replace function public.propose_rule(
  p_group_id uuid, p_title text, p_description text,
  p_trigger jsonb, p_action jsonb, p_exceptions jsonb, p_committee_only boolean
)
returns public.rules language plpgsql security definer set search_path = public as $$
declare r public.rules; v public.votes;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then raise exception 'not a member'; end if;
  insert into public.rules (group_id, title, description, trigger, action, exceptions, status, proposed_by, enabled)
  values (p_group_id, p_title, p_description, p_trigger, p_action, coalesce(p_exceptions, '[]'::jsonb), 'proposed', auth.uid(), false)
  returning * into r;

  v := public.create_vote(p_group_id, 'rule_proposal', r.id, format('Nueva regla: %s', p_title), p_description, null, coalesce(p_committee_only, false));
  update public.rules set approved_via_vote_id = v.id where id = r.id returning * into r;
  return r;
end;
$$;
revoke execute on function public.propose_rule(uuid, text, text, jsonb, jsonb, jsonb, boolean) from public, anon;
grant  execute on function public.propose_rule(uuid, text, text, jsonb, jsonb, jsonb, boolean) to authenticated;

-- Tally a vote and apply side-effects: activate proposed rule / archive on repeal / waive fine on appeal.
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
    end if;
  end if;
  return v;
end;
$$;
revoke execute on function public.close_vote(uuid) from public, anon;
grant  execute on function public.close_vote(uuid) to authenticated;

create or replace function public.close_pot(p_pot_id uuid, p_winner_id uuid)
returns public.pots language plpgsql security definer set search_path = public as $$
declare p public.pots;
begin
  select * into p from public.pots where id = p_pot_id;
  if not found then raise exception 'pot not found'; end if;
  if not (p.created_by = auth.uid() or public.is_group_admin(p.group_id, auth.uid())) then
    raise exception 'not allowed';
  end if;
  update public.pots set status='closed', winner_id = p_winner_id, closed_at = now()
  where id = p_pot_id returning * into p;
  return p;
end;
$$;
revoke execute on function public.close_pot(uuid, uuid) from public, anon;
grant  execute on function public.close_pot(uuid, uuid) to authenticated;

create or replace function public.create_expense_with_shares(
  p_group_id uuid, p_description text, p_amount numeric, p_expense_date date,
  p_split_type text, p_notes text, p_event_id uuid, p_shares jsonb
)
returns public.expenses language plpgsql security definer set search_path = public as $$
declare ex public.expenses; sh jsonb; total numeric := 0;
begin
  if not public.is_group_member(p_group_id, auth.uid()) then raise exception 'not a member'; end if;
  insert into public.expenses (group_id, paid_by, description, amount, expense_date, split_type, notes, event_id)
  values (p_group_id, auth.uid(), p_description, p_amount, coalesce(p_expense_date, current_date),
          coalesce(p_split_type,'equal'), p_notes, p_event_id)
  returning * into ex;
  for sh in select * from jsonb_array_elements(p_shares) loop
    insert into public.expense_shares (expense_id, user_id, amount)
    values (ex.id, (sh->>'user_id')::uuid, (sh->>'amount')::numeric);
    total := total + (sh->>'amount')::numeric;
  end loop;
  if abs(total - p_amount) > 0.01 then raise exception 'shares (%) <> total (%)', total, p_amount; end if;
  return ex;
end;
$$;
revoke execute on function public.create_expense_with_shares(uuid, text, numeric, date, text, text, uuid, jsonb) from public, anon;
grant  execute on function public.create_expense_with_shares(uuid, text, numeric, date, text, text, uuid, jsonb) to authenticated;
