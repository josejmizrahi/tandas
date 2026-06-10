-- R.6.F — Seed 2 reglas demoables que ejercitan el motor R.6.A/B end-to-end.
--
-- Seed 1: Palco Mundial 2026 — Fix existing rule "Alerta gasto >5000 MXN".
--   Bugs shipped previa: trigger_event_type='money.expense_recorded' (no existe; el real es 'expense.recorded'),
--   consequences=[] (vacío → nunca emite nada).
--   Fix: corregir trigger + agregar emit_attention consequence.
--
-- Seed 2: Familia Mizrahi — "Check-in tarde — multa $30 MXN".
--   trigger: event.checked_in
--   condition: minutes_late > 0
--   consequence: fine kind=money amount=30 currency=MXN reason='Llegada tarde a evento de Familia'
--   Ejercita el sink legacy `fine` + idempotency_key (R.6.A) + trigger auto-dispatch (R.6.B).
--
-- Smoke verde 2026-06-08 ambos seeds:
--   - Seed 1: record_expense $6000 en Palco → trigger fires → rule_attention_items row →
--     attention_inbox surfaces "Gasto grande registrado".
--   - Seed 2: INSERT activity_event event.checked_in con minutes_late=12 → trigger fires →
--     obligation $30 MXN creada para Jacobo (debtor).

-- Seed 1 — Fix Palco Mundial expense alerta.
update public.rules
set trigger_event_type = 'expense.recorded',
    title = 'Gasto > 5,000 MXN — alerta al gastador',
    body  = 'Cuando alguien registra un gasto mayor a 5,000 MXN en Palco Mundial, el gastador recibe atención.',
    consequences = jsonb_build_array(
      jsonb_build_object(
        'type','emit_attention',
        'kind','rule_violation',
        'title','Gasto grande registrado',
        'reason','Tu gasto supera $5,000 MXN — revisa que sea correcto',
        'priority','high',
        'cta_action_key','view_context',
        'cta_scope_kind','context',
        'cta_scope_id','4198367e-768b-461b-a05c-07d21a45090c'
      )
    ),
    updated_at = now()
where id = '1e26c5c2-d176-4d92-9ff0-6b631de74a11';

-- Seed 2 — Familia Mizrahi check-in tarde multa $30.
-- R.9 replay fix (2026-06-11): los UUIDs son de la BD viva y no existen en un
-- replay desde cero (edge-tests moría con FK 23503). El seed ya está aplicado
-- en live; aquí se vuelve condicional para que la cadena replaye limpia.
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
       'Check-in tarde — multa $30 MXN',
       'Cuando alguien marca check-in tarde (minutes_late > 0) a un evento de Familia Mizrahi, se emite una multa automática de $30 MXN al participante.',
       'norm', 1, 'active',
       'event.checked_in',
       jsonb_build_object('op','>','field','minutes_late','value',0),
       jsonb_build_array(
         jsonb_build_object(
           'type','fine',
           'kind','money',
           'obligation_type','fine',
           'amount',30,
           'currency','MXN',
           'reason','Llegada tarde a evento de Familia'
         )
       ),
       'event_type',
       '{}'::jsonb,
       'c9f0c0d8-cae5-4ef1-aec4-2418748b5b47'::uuid)
    on conflict do nothing;
  end if;
end $$;
