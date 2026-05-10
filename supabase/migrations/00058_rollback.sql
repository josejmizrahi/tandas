-- 00058 rollback — Restore legacy `rules` columns + previous writer
-- bodies (00054 + 00024 shapes).
--
-- WARNING: this rollback restores the column shape but NOT the data
-- that lived in those columns at apply time. Any rows inserted post-
-- 00058 will have NULLs in the legacy columns. Pre-00058 rows that
-- existed before E.2 will lose any data that wasn't replicated to the
-- platform side — i.e. the tiny fraction of rows that ever had a
-- non-null `description` or `exceptions` cannot be reconstructed.
--
-- If you need to roll back to recover specific data, restore from the
-- pre-00058 backup snapshot first; this script only puts the schema
-- and writer functions back into shape.

-- =========================================================
-- 1. Re-add columns (nullable, no defaults)
-- =========================================================
alter table public.rules
  add column if not exists code                  text,
  add column if not exists title                 text,
  add column if not exists description           text,
  add column if not exists trigger               jsonb,
  add column if not exists action                jsonb,
  add column if not exists enabled               boolean,
  add column if not exists status                text,
  add column if not exists exceptions            jsonb,
  add column if not exists approved_via_vote_id  uuid;

-- Restore the deprecation comments for archaeology.
comment on column public.rules.code         is 'DEPRECATED — drop pre-Fase 2. Use rules.id for stable references.';
comment on column public.rules.title        is 'DEPRECATED — drop pre-Fase 2. Use rules.name (canonical).';
comment on column public.rules.description  is 'DEPRECATED — drop pre-Fase 2. Description embedido en rules.consequences config si necesario.';
comment on column public.rules.trigger      is 'DEPRECATED — drop pre-Fase 2. Use rules.conditions + consequences (Platform shape).';
comment on column public.rules.action       is 'DEPRECATED — drop pre-Fase 2. Use rules.consequences.';
comment on column public.rules.enabled      is 'DEPRECATED — drop pre-Fase 2. Use rules.is_active (canonical).';
comment on column public.rules.status       is 'DEPRECATED — drop pre-Fase 2. Status implicit via rules.is_active=false to disable.';

-- =========================================================
-- 2. Backfill the platform-shape rows so the legacy columns are
--    consistent again. is_active → enabled, name → title, etc.
-- =========================================================
update public.rules
set
  enabled = is_active,
  title   = name,
  status  = case when is_active then 'active' else 'inactive' end
where enabled is null or title is null or status is null;

-- =========================================================
-- 3. Restore archive_rule_on_repeal_pass to write enabled+status
-- =========================================================
create or replace function public.archive_rule_on_repeal_pass()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.vote_type = 'rule_repeal'
     and new.status = 'resolved'
     and old.status = 'open'
     and (new.payload->>'resolution') = 'passed'
     and new.reference_id is not null then
    update public.rules
    set status = 'archived', enabled = false
    where id = new.reference_id;
  end if;
  return new;
end;
$$;

-- =========================================================
-- 4. Restore audit trigger to read enabled / title
-- =========================================================
create or replace function public.emit_rule_mutation_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  select id into v_member_id
  from public.group_members
  where group_id = new.group_id
    and user_id = auth.uid()
    and active
  limit 1;

  if new.enabled is distinct from old.enabled then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleEnabledChanged', new.id, v_member_id, jsonb_build_object(
      'rule_title', new.title,
      'before', old.enabled,
      'after', new.enabled
    ));
  end if;

  if new.consequences is distinct from old.consequences then
    insert into public.system_events (group_id, event_type, resource_id, member_id, payload)
    values (new.group_id, 'ruleAmountChanged', new.id, v_member_id, jsonb_build_object(
      'rule_title', new.title,
      'before', old.consequences,
      'after', new.consequences
    ));
  end if;

  return new;
end;
$$;

-- =========================================================
-- 4. Restore seed_dinner_template_rules (00054 body — dual writes)
-- =========================================================
create or replace function public.seed_dinner_template_rules(
  p_group_id uuid
) returns setof public.rules
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not public.is_group_admin(p_group_id, uid) then
    raise exception 'only group admins can seed template rules';
  end if;

  if exists (
    select 1 from public.rules
     where group_id = p_group_id
       and consequences <> '[]'::jsonb
  ) then
    return;
  end if;

  return query
  insert into public.rules (
    group_id, slug,
    code, title, description, trigger, action,
    name, is_active, conditions, consequences,
    status, enabled, proposed_by
  )
  values
  (
    p_group_id, 'dinner_late_arrival',
    'dinner_late_arrival',
    'Llegada tardía',
    'Multa escalonada por llegar después de la hora de la cena',
    jsonb_build_object('eventType', 'checkInRecorded', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Llegada tardía',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'checkInMinutesLate', 'config', jsonb_build_object('thresholdMinutes', 0))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('baseAmount', 200, 'stepAmount', 50, 'stepMinutes', 30))
    ),
    'active', true, uid
  ),
  (
    p_group_id, 'dinner_no_response',
    'dinner_no_response',
    'No confirmó a tiempo',
    'Multa para quien no respondió RSVP antes del cierre',
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'No confirmó a tiempo',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'pending'))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', true, uid
  ),
  (
    p_group_id, 'dinner_same_day_cancel',
    'dinner_same_day_cancel',
    'Cancelación mismo día',
    'Multa por cancelar la asistencia el mismo día del evento',
    jsonb_build_object('eventType', 'rsvpChangedSameDay', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Cancelación mismo día',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'alwaysTrue', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', true, uid
  ),
  (
    p_group_id, 'dinner_no_show',
    'dinner_no_show',
    'No-show',
    'Multa para quien confirmó asistencia pero no llegó',
    jsonb_build_object('eventType', 'eventClosed', 'config', '{}'::jsonb),
    jsonb_build_object('type', 'fine', 'amount_mxn', 300),
    'No-show',
    true,
    jsonb_build_array(
      jsonb_build_object('type', 'responseStatusIs', 'config', jsonb_build_object('status', 'going')),
      jsonb_build_object('type', 'checkInExists',     'config', jsonb_build_object('exists', false))
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 300))
    ),
    'active', true, uid
  ),
  (
    p_group_id, 'dinner_host_no_menu',
    'dinner_host_no_menu',
    'Anfitrión sin menú',
    'Multa para el host si no llenó la descripción 24h antes',
    jsonb_build_object('eventType', 'hoursBeforeEvent', 'config', jsonb_build_object('hours', 24)),
    jsonb_build_object('type', 'fine', 'amount_mxn', 200),
    'Anfitrión sin menú',
    false,
    jsonb_build_array(
      jsonb_build_object('type', 'eventDescriptionMissing', 'config', '{}'::jsonb)
    ),
    jsonb_build_array(
      jsonb_build_object('type', 'fine', 'config', jsonb_build_object('amount', 200))
    ),
    'active', false, uid
  )
  returning *;
end;
$$;

-- =========================================================
-- 5. Restore create_initial_rule (00054 body — code-translating writer)
-- =========================================================
drop function if exists public.create_initial_rule(uuid, text, text, boolean, jsonb, jsonb, jsonb);

create or replace function public.create_initial_rule(
  p_group_id    uuid,
  p_code        text,
  p_title       text,
  p_description text,
  p_trigger     jsonb,
  p_action      jsonb
) returns public.rules
language plpgsql security definer set search_path = public as $$
declare
  r              public.rules;
  v_slug         text;
  v_event_type   text;
  v_conditions   jsonb;
  v_consequences jsonb;
  v_platform_trigger jsonb;
  v_amount       int := coalesce((p_action ->> 'amount_mxn')::int, 200);
begin
  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can seed rules';
  end if;

  case p_code
    when 'late' then
      v_slug         := 'dinner_late_arrival';
      v_event_type   := 'checkInRecorded';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'checkInMinutesLate',
                           'config', jsonb_build_object('thresholdMinutes', 0))
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object(
                             'baseAmount',  v_amount,
                             'stepAmount',  50,
                             'stepMinutes', 30))
      );
    when 'no_rsvp' then
      v_slug         := 'dinner_no_response';
      v_event_type   := 'eventClosed';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'responseStatusIs',
                           'config', jsonb_build_object('status', 'pending'))
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object('amount', v_amount))
      );
    when 'cancel_same_day' then
      v_slug         := 'dinner_same_day_cancel';
      v_event_type   := 'rsvpChangedSameDay';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'alwaysTrue', 'config', '{}'::jsonb)
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object('amount', v_amount))
      );
    when 'no_show' then
      v_slug         := 'dinner_no_show';
      v_event_type   := 'eventClosed';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'responseStatusIs',
                           'config', jsonb_build_object('status', 'going')),
        jsonb_build_object('type', 'checkInExists',
                           'config', jsonb_build_object('exists', false))
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object('amount', v_amount))
      );
    when 'host_no_menu' then
      v_slug         := 'dinner_host_no_menu';
      v_event_type   := 'hoursBeforeEvent';
      v_conditions   := jsonb_build_array(
        jsonb_build_object('type', 'eventDescriptionMissing', 'config', '{}'::jsonb)
      );
      v_consequences := jsonb_build_array(
        jsonb_build_object('type', 'fine',
                           'config', jsonb_build_object('amount', v_amount))
      );
    else
      v_slug         := null;
      v_event_type   := null;
      v_conditions   := '[]'::jsonb;
      v_consequences := '[]'::jsonb;
  end case;

  v_platform_trigger := case
    when v_event_type is null then p_trigger
    else jsonb_build_object('eventType', v_event_type, 'config', '{}'::jsonb)
  end;

  insert into public.rules (
    group_id, slug,
    code, title, description, trigger, action, status, enabled,
    name, is_active, conditions, consequences,
    proposed_by
  ) values (
    p_group_id, v_slug,
    p_code, p_title, p_description, v_platform_trigger, p_action, 'active', true,
    p_title, true, v_conditions, v_consequences,
    auth.uid()
  ) returning * into r;
  return r;
end;
$$;

revoke execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) from public, anon;
grant  execute on function public.create_initial_rule(uuid, text, text, text, jsonb, jsonb) to authenticated;
