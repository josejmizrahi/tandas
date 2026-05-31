-- Refactor evaluate_rules_for_event con p_mode + depth guard.
-- doctrine_rule_eval_sync_async.md: sync para canónico, async para side effects.
-- Las consecuencias canónicas (sanction/obligation/membership state) siguen
-- siendo emitidas por las RPCs de dominio que invocan esta función después
-- de mutar su tabla principal y emitir su group_event. Esta función NO
-- aplica consecuencias de motor directamente — registra la evaluación y
-- deja las consecuencias declarativas en jsonb para que el dispatcher
-- (V1: la propia RPC; V2: edge function) las ejecute con autoridad
-- explícita.

drop function if exists public.evaluate_rules_for_event(uuid);

create or replace function public.evaluate_rules_for_event(
  p_event_uuid_id uuid,
  p_mode          text default 'sync'
)
returns setof uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_depth     int := coalesce(nullif(current_setting('ruul.rule_eval_depth', true), '')::int, 0);
  v_max_depth constant int := 5;
  v_event     public.group_events%rowtype;
  v_rv        public.group_rule_versions%rowtype;
  v_eval_id   uuid;
  v_idem      text;
begin
  if v_depth >= v_max_depth then
    raise exception 'rule evaluation depth % exceeds max % for event %',
      v_depth, v_max_depth, p_event_uuid_id;
  end if;
  -- is_local := true → reset al fin de transacción
  perform set_config('ruul.rule_eval_depth', (v_depth + 1)::text, true);

  if p_mode not in ('sync','async') then
    raise exception 'invalid mode %', p_mode;
  end if;

  select * into v_event from public.group_events where uuid_id = p_event_uuid_id;
  if v_event.id is null then
    raise exception 'event % not found', p_event_uuid_id;
  end if;

  for v_rv in
    select rv.* from public.group_rule_versions rv
    join public.group_rules r on r.current_version_id = rv.id
    where r.group_id = v_event.group_id
      and r.status = 'active'
      and rv.execution_mode = 'engine'
      and rv.trigger_event_type = v_event.event_type
  loop
    v_idem := p_event_uuid_id::text || '|' || v_rv.id::text;
    insert into public.group_rule_evaluations (
      rule_version_id, group_id, source_event_id, matched, consequences_emitted, idempotency_key
    ) values (
      v_rv.id, v_event.group_id, p_event_uuid_id, true,
      coalesce(v_rv.consequences, '[]'::jsonb), v_idem
    )
    on conflict (idempotency_key) do nothing
    returning id into v_eval_id;
    if v_eval_id is not null then
      return next v_eval_id;
    end if;
  end loop;

  -- Async path: encolar dispatcher para side effects no canónicos.
  -- Sync path: la RPC llamante ya está aplicando consecuencias canónicas
  -- dentro de la misma transacción (insertando obligation/sanction/etc),
  -- no se necesita post-trabajo.
  if p_mode = 'async' then
    insert into public.notifications_outbox (group_id, recipient_user_id, category, payload)
    select v_event.group_id, v_event.actor_user_id, 'rule_evaluated',
           jsonb_build_object('event_uuid_id', p_event_uuid_id, 'event_type', v_event.event_type)
    where v_event.actor_user_id is not null;
  end if;

  return;
end;
$$;

comment on function public.evaluate_rules_for_event(uuid, text) is
  'Doctrine: doctrine_rule_eval_sync_async.md. RPCs de dominio llaman con p_mode=''sync'' después de mutar su tabla principal y emitir group_event, antes del commit. Las consecuencias canónicas las emite la RPC llamante (no esta función). p_mode=''async'' encola side effects no canónicos.';

-- Mantén el revoke from anon (la firma cambió, hay que re-aplicar).
revoke execute on function public.evaluate_rules_for_event(uuid, text) from anon, public;

-- mark_no_show fue creada con la firma vieja; rewire a la nueva.
create or replace function public.mark_no_show(
  p_resource_id   uuid,
  p_membership_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_r public.group_resources%rowtype; v_event_uuid uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.update');

  select rse.uuid_id into v_event_uuid from public.record_system_event(
    v_r.group_id, 'check_in.missed', 'resource', p_resource_id,
    'Miembro no se presentó',
    jsonb_build_object('membership_id', p_membership_id)
  ) rse;
  perform public.evaluate_rules_for_event(v_event_uuid, 'sync');
end;
$$;
