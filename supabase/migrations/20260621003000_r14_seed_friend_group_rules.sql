-- R.14 — Seed automático de reglas al crear un grupo de amigos.
--
-- Friend Groups Launch P0 #2: hoy un grupo nuevo arranca con 0 reglas, y el
-- founder debe descubrir que existe la biblioteca de presets. Esta mig agrega
-- un trigger AFTER INSERT en `actors` que, cuando se crea un actor con
-- `actor_subtype='friend_group'`, siembra 2 reglas opt-out que ya funcionan:
--
--   Seed 1: Llegar tarde — multa $30 MXN
--     trigger: event.checked_in (payload: minutes_late)
--     condition: minutes_late > 15
--     consequence: fine $30 al participante
--
--   Seed 2: Gasto grande (>$5,000 MXN) — alerta al gastador
--     trigger: expense.recorded (payload: amount, currency)
--     condition: amount > 5000
--     consequence: emit_attention al gastador (sin multa)
--
-- Opt-out: si el creador pasa `metadata.r14_skip_seed_rules=true` al
-- create_context, no se siembran. Útil para data imports / restores.
--
-- Idempotency: WHERE NOT EXISTS por (context_actor_id, title). Re-aplicación
-- de la mig es no-op para contextos ya seedeados.
--
-- Smoke verde 2026-06-21:
--   INSERT actor friend_group → trigger dispara → 2 reglas insertadas.
--   PERFORM _r14_seed_friend_group_rules manual segundo tiempo → 0 dups.

create or replace function public._r14_seed_friend_group_rules(
  p_context_id uuid,
  p_creator_actor_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Seed 1: late check-in fine.
  insert into public.rules
    (context_actor_id, title, body, rule_type, severity, status,
     trigger_event_type, condition_tree, consequences,
     target_scope, target_filter, created_by_actor_id)
  select
    p_context_id,
    'Llegar tarde — multa $30 MXN',
    'Cuando alguien hace check-in con más de 15 minutos de retraso al evento, se le aplica una multa automática de $30 MXN. Edita o desactiva esta regla desde Ajustes > Cómo funciona el grupo.',
    'norm', 1, 'active',
    'event.checked_in',
    jsonb_build_object('op', '>', 'field', 'minutes_late', 'value', 15),
    jsonb_build_array(
      jsonb_build_object(
        'type', 'fine',
        'kind', 'money',
        'obligation_type', 'fine',
        'amount', 30,
        'currency', 'MXN',
        'reason', 'Llegada tarde al evento'
      )
    ),
    'event_type',
    '{}'::jsonb,
    p_creator_actor_id
  where not exists (
    select 1 from public.rules
    where context_actor_id = p_context_id
      and title = 'Llegar tarde — multa $30 MXN'
  );

  -- Seed 2: large expense alert.
  insert into public.rules
    (context_actor_id, title, body, rule_type, severity, status,
     trigger_event_type, condition_tree, consequences,
     target_scope, target_filter, created_by_actor_id)
  select
    p_context_id,
    'Gasto grande (>$5,000 MXN) — alerta al gastador',
    'Cuando alguien registra un gasto mayor a $5,000 MXN, se le envía una notificación de atención para confirmar el monto. Sin multa.',
    'norm', 1, 'active',
    'expense.recorded',
    jsonb_build_object('op', '>', 'field', 'amount', 'value', 5000),
    jsonb_build_array(
      jsonb_build_object(
        'type', 'emit_attention',
        'kind', 'rule_violation',
        'title', 'Gasto grande registrado',
        'reason', 'Tu gasto supera $5,000 MXN — revisa que sea correcto',
        'priority', 'high',
        'cta_action_key', 'view_context',
        'cta_scope_kind', 'context',
        'cta_scope_id', p_context_id::text
      )
    ),
    'event_type',
    '{}'::jsonb,
    p_creator_actor_id
  where not exists (
    select 1 from public.rules
    where context_actor_id = p_context_id
      and title = 'Gasto grande (>$5,000 MXN) — alerta al gastador'
  );
end;
$$;

revoke all on function public._r14_seed_friend_group_rules(uuid, uuid) from public, anon;
grant execute on function public._r14_seed_friend_group_rules(uuid, uuid) to authenticated, service_role;

create or replace function public._r14_seed_on_friend_group_create()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Solo aplicamos a contextos friend_group con creador conocido.
  if new.actor_subtype = 'friend_group'
     and new.is_context = true
     and new.created_by_actor_id is not null
     and not coalesce((new.metadata->>'r14_skip_seed_rules')::boolean, false)
  then
    -- Defensive: si la siembra falla por cualquier razón (p.ej. shape
    -- futuro de rules cambió), NO bloqueamos la creación del contexto.
    -- El founder puede correr la biblioteca de presets a mano.
    begin
      perform public._r14_seed_friend_group_rules(new.id, new.created_by_actor_id);
    exception when others then
      raise warning 'r14 seed failed for context %: %', new.id, sqlerrm;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_r14_seed_friend_group_rules on public.actors;
create trigger trg_r14_seed_friend_group_rules
  after insert on public.actors
  for each row
  execute function public._r14_seed_on_friend_group_create();
