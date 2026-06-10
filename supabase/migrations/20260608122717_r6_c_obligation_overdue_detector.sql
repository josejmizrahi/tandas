-- R.6.C — Cron-tick virtual event detector: `obligation.overdue`.
--
-- Patrón: cada 15 min, scan obligations vencidas (due_at < now() AND status='open')
-- que no se hayan reportado todavía (metadata->>'r6_overdue_emitted_at' IS NULL).
-- Para cada una, INSERT activity_event `obligation.overdue` con payload completo.
--
-- El trigger R.6.B `_r6_dispatch_rule_eval` AFTER INSERT activity_events ya lo recoge
-- → cualquier rule subscribed a `obligation.overdue` fires → emit_attention sink envía
-- al debtor → iOS AttentionDispatcher routea.
--
-- Idempotency dual:
--   1. metadata->>'r6_overdue_emitted_at' marca obligation como "ya reportada"; en cada
--      tick filtramos las que ya tienen este timestamp.
--   2. rule_evaluations.idempotency_key (R.6.A) protege contra reentradas si el detector
--      corre 2x para el mismo obligation (caso patológico).
--
-- Smoke verde 2026-06-08:
--   - 1 obligation backdated → detector emit 1 → rule_attention_items row → inbox surface.
--   - 2do tick: emit_count = 0 (idempotency vía metadata flag).

create or replace function public._r6_emit_overdue_obligations()
returns integer
language plpgsql
security definer
set search_path to public, auth
set row_security to off
as $$
declare
  v_o record;
  v_count integer := 0;
  v_days_overdue integer;
begin
  for v_o in
    select id, context_actor_id, debtor_actor_id, creditor_actor_id,
           obligation_kind, obligation_type, amount, currency, due_at, title, metadata
      from public.obligations
     where status = 'open'
       and due_at is not null
       and due_at < now()
       and not coalesce(metadata ? 'r6_overdue_emitted_at', false)
     order by due_at asc
     limit 200
  loop
    v_days_overdue := greatest(0, extract(day from (now() - v_o.due_at))::int);

    -- Emit activity_event. NEW.actor_id = debtor (= subject of attention).
    insert into public.activity_events
      (context_actor_id, actor_id, event_type, subject_type, subject_id, obligation_id, payload)
    values
      (v_o.context_actor_id, v_o.debtor_actor_id,
       'obligation.overdue',
       'obligation', v_o.id, v_o.id,
       jsonb_build_object(
         'obligation_id', v_o.id,
         'debtor_actor_id', v_o.debtor_actor_id,
         'creditor_actor_id', v_o.creditor_actor_id,
         'obligation_kind', v_o.obligation_kind,
         'obligation_type', v_o.obligation_type,
         'amount', v_o.amount,
         'currency', v_o.currency,
         'due_at', v_o.due_at,
         'days_overdue', v_days_overdue,
         'title', v_o.title,
         'r6_virtual', true));

    -- Mark obligation como reportada (idempotency).
    update public.obligations
       set metadata = coalesce(metadata, '{}'::jsonb)
                      || jsonb_build_object('r6_overdue_emitted_at', now())
     where id = v_o.id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Schedule cada 15 min vía pg_cron. Unschedule previo para idempotency de la mig.
do $$
begin
  perform cron.unschedule('r6-overdue-obligations');
exception when others then
  null;
end $$;

select cron.schedule(
  'r6-overdue-obligations',
  '*/15 * * * *',
  $$select public._r6_emit_overdue_obligations();$$
);

-- Seed rule en Familia Mizrahi.
-- R.9 replay fix (2026-06-11): UUIDs de la BD viva — condicional para que el
-- replay desde cero no muera con FK 23503 (el seed ya está aplicado en live).
do $$
begin
  if exists (select 1 from public.actors where id = 'afa227dd-31e5-471a-9d40-178ef50038f4')
     and exists (select 1 from public.actors where id = 'c9f0c0d8-cae5-4ef1-aec4-2418748b5b47')
  then
    insert into public.rules
      (context_actor_id, title, body, rule_type, severity, status,
       trigger_event_type, condition_tree, consequences,
       target_scope, target_filter, created_by_actor_id)
    values
      ('afa227dd-31e5-471a-9d40-178ef50038f4',
       'Obligación vencida — alerta crítica al deudor',
       'Cuando una obligación pasa su fecha de vencimiento, el deudor recibe atención inmediata con priority=critical.',
       'norm', 1, 'active',
       'obligation.overdue',
       '{}'::jsonb,
       jsonb_build_array(
         jsonb_build_object(
           'type','emit_attention',
           'kind','rule_violation',
           'title','Obligación vencida',
           'reason','Tienes una obligación que pasó su fecha de pago',
           'priority','critical',
           'cta_action_key','view_context',
           'cta_scope_kind','context',
           'cta_scope_id','afa227dd-31e5-471a-9d40-178ef50038f4'
         )
       ),
       'event_type',
       '{}'::jsonb,
       'c9f0c0d8-cae5-4ef1-aec4-2418748b5b47'::uuid)
    on conflict do nothing;
  end if;
end $$;
