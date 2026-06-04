-- ============================================================================
-- R.3A.2 — Subscriptions + activity catalog events
-- ============================================================================
-- Las personas NO siguen personas (estilo Instagram). Las personas se suscriben
-- a CONTEXTOS, RECURSOS, DECISIONES, EVENTOS, OBLIGACIONES y opcionalmente a
-- otros actores RELEVANTES. La suscripción NO otorga permisos.
--
-- Tipos de suscripción (peso para feed ranking definido en activity_feed):
--   owner_interest = 100   (auto-deducido para owners)
--   stakeholder    = 80    (parte interesada explícita)
--   audit          = 65    (vigilancia, regulador, auditor)
--   watch          = 50    (interés operativo)
--   follow         = 30    (interés liviano)
-- ============================================================================

create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  subscriber_actor_id uuid not null references public.actors(id) on delete cascade,

  -- Target polimórfico — exactly one
  target_type text not null check (target_type in ('actor','context','resource','decision','event','obligation')),
  target_actor_id      uuid references public.actors(id) on delete cascade,
  target_resource_id   uuid references public.resources(id) on delete cascade,
  target_decision_id   uuid references public.decisions(id) on delete cascade,
  target_event_id      uuid references public.calendar_events(id) on delete cascade,
  target_obligation_id uuid references public.obligations(id) on delete cascade,

  subscription_type text not null check (subscription_type in (
    'watch','follow','stakeholder','audit','owner_interest'
  )),

  notes text,
  created_at timestamptz not null default now(),
  removed_at timestamptz,

  constraint subscriptions_exactly_one_target check (
    (case when target_type in ('actor','context') and target_actor_id is not null then 1 else 0 end) +
    (case when target_type = 'resource' and target_resource_id is not null then 1 else 0 end) +
    (case when target_type = 'decision' and target_decision_id is not null then 1 else 0 end) +
    (case when target_type = 'event' and target_event_id is not null then 1 else 0 end) +
    (case when target_type = 'obligation' and target_obligation_id is not null then 1 else 0 end)
    = 1
  )
);

-- Unique active subscription per (subscriber, target) regardless of type
create unique index if not exists subscriptions_unique_actor
  on public.subscriptions (subscriber_actor_id, target_actor_id)
  where removed_at is null and target_actor_id is not null;

create unique index if not exists subscriptions_unique_resource
  on public.subscriptions (subscriber_actor_id, target_resource_id)
  where removed_at is null and target_resource_id is not null;

create unique index if not exists subscriptions_unique_decision
  on public.subscriptions (subscriber_actor_id, target_decision_id)
  where removed_at is null and target_decision_id is not null;

create unique index if not exists subscriptions_unique_event
  on public.subscriptions (subscriber_actor_id, target_event_id)
  where removed_at is null and target_event_id is not null;

create unique index if not exists subscriptions_unique_obligation
  on public.subscriptions (subscriber_actor_id, target_obligation_id)
  where removed_at is null and target_obligation_id is not null;

create index if not exists subscriptions_subscriber_idx
  on public.subscriptions (subscriber_actor_id) where removed_at is null;

alter table public.subscriptions enable row level security;

-- RLS: caller can read/write own subscriptions
drop policy if exists subscriptions_self_read on public.subscriptions;
create policy subscriptions_self_read on public.subscriptions
  for select to authenticated
  using (subscriber_actor_id = public.current_actor_id());

drop policy if exists subscriptions_self_insert on public.subscriptions;
create policy subscriptions_self_insert on public.subscriptions
  for insert to authenticated
  with check (subscriber_actor_id = public.current_actor_id());

drop policy if exists subscriptions_self_update on public.subscriptions;
create policy subscriptions_self_update on public.subscriptions
  for update to authenticated
  using (subscriber_actor_id = public.current_actor_id());

comment on table public.subscriptions is
'R.3A: a quién/qué quiero recibir señales. NO otorga permisos. NO es followers.';

-- ────────────────────────────────────────────────────────────────────────────
-- Activity event catalog: nuevos eventos R.3A
-- ────────────────────────────────────────────────────────────────────────────
insert into public.activity_event_catalog (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('subscription.created', 'subscription', 'Un actor se suscribió a algo', 'subscription', false),
  ('subscription.removed', 'subscription', 'Un actor canceló una suscripción', 'subscription', false),
  ('stakeholder.added',    'subscription', 'Un actor fue marcado como stakeholder', 'subscription', false),
  ('stakeholder.removed',  'subscription', 'Un stakeholder fue removido', 'subscription', false),
  ('trust.created', 'trust', 'Un edge de confianza fue declarado', 'trust_edge', false),
  ('trust.updated', 'trust', 'Un edge de confianza fue actualizado', 'trust_edge', false),
  ('trust.removed', 'trust', 'Un edge de confianza fue removido', 'trust_edge', false)
on conflict (event_type) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- subscribe(p_target_type, p_target_id, p_subscription_type, p_notes?)
-- Reactiva si ya existe (removed_at IS NOT NULL) — idempotente.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.subscribe(
  p_target_type text,
  p_target_id uuid,
  p_subscription_type text default 'follow',
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_context_actor_id uuid;
  v_target_actor_id uuid;
  v_target_resource_id uuid;
  v_target_decision_id uuid;
  v_target_event_id uuid;
  v_target_obligation_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode='28000'; end if;
  if p_target_type not in ('actor','context','resource','decision','event','obligation') then
    raise exception 'invalid target_type %', p_target_type using errcode='22023';
  end if;
  if p_subscription_type not in ('watch','follow','stakeholder','audit','owner_interest') then
    raise exception 'invalid subscription_type %', p_subscription_type using errcode='22023';
  end if;

  -- Resolve target and derive context for activity event
  if p_target_type in ('actor','context') then
    v_target_actor_id := p_target_id;
    v_context_actor_id := p_target_id;
  elsif p_target_type = 'resource' then
    v_target_resource_id := p_target_id;
    select canonical_owner_actor_id into v_context_actor_id from public.resources where id = p_target_id;
  elsif p_target_type = 'decision' then
    v_target_decision_id := p_target_id;
    select context_actor_id into v_context_actor_id from public.decisions where id = p_target_id;
  elsif p_target_type = 'event' then
    v_target_event_id := p_target_id;
    select context_actor_id into v_context_actor_id from public.calendar_events where id = p_target_id;
  elsif p_target_type = 'obligation' then
    v_target_obligation_id := p_target_id;
    select context_actor_id into v_context_actor_id from public.obligations where id = p_target_id;
  end if;

  -- Reactivate existing row if soft-removed; else insert
  update public.subscriptions
     set removed_at = null,
         subscription_type = p_subscription_type,
         notes = coalesce(p_notes, notes)
   where subscriber_actor_id = v_caller
     and (
       (p_target_type in ('actor','context') and target_actor_id = p_target_id) or
       (p_target_type = 'resource' and target_resource_id = p_target_id) or
       (p_target_type = 'decision' and target_decision_id = p_target_id) or
       (p_target_type = 'event' and target_event_id = p_target_id) or
       (p_target_type = 'obligation' and target_obligation_id = p_target_id)
     )
   returning id into v_id;

  if v_id is null then
    insert into public.subscriptions (
      subscriber_actor_id, target_type,
      target_actor_id, target_resource_id, target_decision_id, target_event_id, target_obligation_id,
      subscription_type, notes
    ) values (
      v_caller, p_target_type,
      v_target_actor_id, v_target_resource_id, v_target_decision_id, v_target_event_id, v_target_obligation_id,
      p_subscription_type, p_notes
    )
    returning id into v_id;
  end if;

  -- Emit activity (best effort — only if we resolved a context)
  if v_context_actor_id is not null then
    perform public._emit_activity(
      v_context_actor_id, v_caller,
      case when p_subscription_type = 'stakeholder' then 'stakeholder.added' else 'subscription.created' end,
      'subscription', v_id,
      jsonb_build_object(
        'target_type', p_target_type,
        'target_id', p_target_id,
        'subscription_type', p_subscription_type
      )
    );
  end if;

  return v_id;
end; $$;

revoke all on function public.subscribe(text, uuid, text, text) from public, anon;
grant execute on function public.subscribe(text, uuid, text, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- unsubscribe(p_subscription_id)
-- Idempotente. Soft-remove (removed_at).
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.unsubscribe(p_subscription_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_row public.subscriptions;
  v_context uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode='28000'; end if;

  select * into v_row from public.subscriptions
   where id = p_subscription_id and subscriber_actor_id = v_caller;
  if not found then return false; end if;
  if v_row.removed_at is not null then return false; end if;

  update public.subscriptions set removed_at = now() where id = p_subscription_id;

  -- Best-effort: emit activity in the same context as the subscribe call
  v_context := coalesce(
    v_row.target_actor_id,
    (select canonical_owner_actor_id from public.resources where id = v_row.target_resource_id),
    (select context_actor_id from public.decisions where id = v_row.target_decision_id),
    (select context_actor_id from public.calendar_events where id = v_row.target_event_id),
    (select context_actor_id from public.obligations where id = v_row.target_obligation_id)
  );
  if v_context is not null then
    perform public._emit_activity(
      v_context, v_caller,
      case when v_row.subscription_type = 'stakeholder' then 'stakeholder.removed' else 'subscription.removed' end,
      'subscription', v_row.id,
      jsonb_build_object(
        'target_type', v_row.target_type,
        'subscription_type', v_row.subscription_type
      )
    );
  end if;

  return true;
end; $$;

revoke all on function public.unsubscribe(uuid) from public, anon;
grant execute on function public.unsubscribe(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- mark_as_stakeholder(p_target_type, p_target_id, p_actor_id?)
-- Atajo idiomático para subscribe(..., 'stakeholder'). Si p_actor_id != caller,
-- requiere capability — por ahora, sólo caller puede marcarse a sí mismo. Para
-- terceros se modela vía actor_relationships (advisor_of/board_member_of/etc).
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.mark_as_stakeholder(
  p_target_type text,
  p_target_id uuid,
  p_actor_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode='28000'; end if;
  if p_actor_id is not null and p_actor_id <> v_caller then
    raise exception 'cannot mark another actor as stakeholder; use actor_relationships' using errcode='42501';
  end if;
  return public.subscribe(p_target_type, p_target_id, 'stakeholder', null);
end; $$;

revoke all on function public.mark_as_stakeholder(text, uuid, uuid) from public, anon;
grant execute on function public.mark_as_stakeholder(text, uuid, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- list_my_subscriptions() — devuelve jsonb con todas las suscripciones activas
-- del caller, enriquecidas con target_display_name cuando aplica.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.list_my_subscriptions()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode='28000'; end if;

  return jsonb_build_object(
    'subscriber_actor_id', v_caller,
    'subscriptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'target_type', s.target_type,
        'target_actor_id', s.target_actor_id,
        'target_resource_id', s.target_resource_id,
        'target_decision_id', s.target_decision_id,
        'target_event_id', s.target_event_id,
        'target_obligation_id', s.target_obligation_id,
        'subscription_type', s.subscription_type,
        'notes', s.notes,
        'created_at', s.created_at,
        'target_display_name', coalesce(
          a.display_name,
          r.display_name,
          d.title,
          ce.title,
          o.title
        )
      ) order by s.created_at desc)
      from public.subscriptions s
      left join public.actors          a  on a.id  = s.target_actor_id
      left join public.resources       r  on r.id  = s.target_resource_id
      left join public.decisions       d  on d.id  = s.target_decision_id
      left join public.calendar_events ce on ce.id = s.target_event_id
      left join public.obligations     o  on o.id  = s.target_obligation_id
      where s.subscriber_actor_id = v_caller
        and s.removed_at is null
    ), '[]'::jsonb)
  );
end; $$;

revoke all on function public.list_my_subscriptions() from public, anon;
grant execute on function public.list_my_subscriptions() to authenticated, service_role;
