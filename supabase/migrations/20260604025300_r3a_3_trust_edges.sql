-- ============================================================================
-- R.3A.3 — Trust graph foundation
-- ============================================================================
-- Trust = confianza DECLARADA por un actor hacia otro. NO otorga permisos, NO
-- otorga rights, NO otorga votos. Solamente representa una relación de
-- confianza subjetiva. Futuro: reputation, delegation, recommendations.
--
-- trust_level 1-5 (Likert). Source = caller (current_actor_id). Soft remove.
-- Unique per (source, target, trust_type) activo — un mismo tipo no duplica.
-- ============================================================================

create table if not exists public.trust_edges (
  id uuid primary key default gen_random_uuid(),
  source_actor_id uuid not null references public.actors(id) on delete cascade,
  target_actor_id uuid not null references public.actors(id) on delete cascade,
  trust_level int not null check (trust_level between 1 and 5),
  trust_type text not null check (trust_type in (
    'personal','professional','financial','governance','advisory'
  )),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  removed_at timestamptz,
  constraint trust_edges_no_self check (source_actor_id <> target_actor_id)
);

create unique index if not exists trust_edges_unique_active
  on public.trust_edges (source_actor_id, target_actor_id, trust_type)
  where removed_at is null;

create index if not exists trust_edges_source_idx on public.trust_edges (source_actor_id) where removed_at is null;
create index if not exists trust_edges_target_idx on public.trust_edges (target_actor_id) where removed_at is null;

alter table public.trust_edges enable row level security;

-- RLS: caller puede leer/escribir SUS edges (source). El target puede leer los
-- que apuntan hacia él (transparencia). Nadie más.
drop policy if exists trust_edges_self_read on public.trust_edges;
create policy trust_edges_self_read on public.trust_edges
  for select to authenticated
  using (source_actor_id = public.current_actor_id() or target_actor_id = public.current_actor_id());

drop policy if exists trust_edges_self_insert on public.trust_edges;
create policy trust_edges_self_insert on public.trust_edges
  for insert to authenticated
  with check (source_actor_id = public.current_actor_id());

drop policy if exists trust_edges_self_update on public.trust_edges;
create policy trust_edges_self_update on public.trust_edges
  for update to authenticated
  using (source_actor_id = public.current_actor_id());

comment on table public.trust_edges is
'R.3A: confianza declarada entre actores. NO otorga permisos/rights/votos. Alimentará reputation/delegation a futuro.';

-- ────────────────────────────────────────────────────────────────────────────
-- add_trust(p_target_actor_id, p_trust_level, p_trust_type, p_notes?)
-- Reactiva + actualiza si ya existe (idempotente por (source, target, type)).
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.add_trust(
  p_target_actor_id uuid,
  p_trust_level int,
  p_trust_type text default 'personal',
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode='28000'; end if;
  if v_caller = p_target_actor_id then
    raise exception 'cannot trust self' using errcode='22023';
  end if;
  if p_trust_level not between 1 and 5 then
    raise exception 'trust_level must be 1..5' using errcode='22023';
  end if;
  if p_trust_type not in ('personal','professional','financial','governance','advisory') then
    raise exception 'invalid trust_type %', p_trust_type using errcode='22023';
  end if;

  update public.trust_edges
     set trust_level = p_trust_level,
         notes = coalesce(p_notes, notes),
         updated_at = now(),
         removed_at = null
   where source_actor_id = v_caller
     and target_actor_id = p_target_actor_id
     and trust_type = p_trust_type
   returning id into v_id;

  if v_id is null then
    insert into public.trust_edges (source_actor_id, target_actor_id, trust_level, trust_type, notes)
    values (v_caller, p_target_actor_id, p_trust_level, p_trust_type, p_notes)
    returning id into v_id;

    -- emit activity in caller's personal context
    perform public._emit_activity(
      v_caller, v_caller, 'trust.created', 'trust_edge', v_id,
      jsonb_build_object(
        'target_actor_id', p_target_actor_id,
        'trust_level', p_trust_level,
        'trust_type', p_trust_type
      )
    );
  else
    perform public._emit_activity(
      v_caller, v_caller, 'trust.updated', 'trust_edge', v_id,
      jsonb_build_object(
        'target_actor_id', p_target_actor_id,
        'trust_level', p_trust_level,
        'trust_type', p_trust_type
      )
    );
  end if;

  return v_id;
end; $$;

revoke all on function public.add_trust(uuid, int, text, text) from public, anon;
grant execute on function public.add_trust(uuid, int, text, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- remove_trust(p_trust_edge_id) — soft remove, idempotente.
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.remove_trust(p_trust_edge_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_row public.trust_edges;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode='28000'; end if;
  select * into v_row from public.trust_edges
    where id = p_trust_edge_id and source_actor_id = v_caller;
  if not found then return false; end if;
  if v_row.removed_at is not null then return false; end if;

  update public.trust_edges set removed_at = now(), updated_at = now() where id = p_trust_edge_id;
  perform public._emit_activity(
    v_caller, v_caller, 'trust.removed', 'trust_edge', v_row.id,
    jsonb_build_object('target_actor_id', v_row.target_actor_id, 'trust_type', v_row.trust_type)
  );
  return true;
end; $$;

revoke all on function public.remove_trust(uuid) from public, anon;
grant execute on function public.remove_trust(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- list_trust_network(p_actor_id?) — caller-scoped. Devuelve edges OUTGOING e
-- INCOMING activos. Si p_actor_id != caller, solo el caller puede leer sobre
-- sí mismo (RLS filtra el resto).
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.list_trust_network(p_actor_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_actor uuid := coalesce(p_actor_id, v_caller);
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode='28000'; end if;

  return jsonb_build_object(
    'actor_id', v_actor,
    'outgoing', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'target_actor_id', t.target_actor_id,
        'target_display_name', a.display_name,
        'trust_level', t.trust_level,
        'trust_type', t.trust_type,
        'notes', t.notes,
        'created_at', t.created_at,
        'updated_at', t.updated_at
      ) order by t.trust_level desc, t.created_at desc)
      from public.trust_edges t
      join public.actors a on a.id = t.target_actor_id
      where t.source_actor_id = v_actor and t.removed_at is null
        and (v_actor = v_caller or t.target_actor_id = v_caller)
    ), '[]'::jsonb),
    'incoming', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'source_actor_id', t.source_actor_id,
        'source_display_name', a.display_name,
        'trust_level', t.trust_level,
        'trust_type', t.trust_type,
        'created_at', t.created_at
      ) order by t.trust_level desc, t.created_at desc)
      from public.trust_edges t
      join public.actors a on a.id = t.source_actor_id
      where t.target_actor_id = v_actor and t.removed_at is null
        and (v_actor = v_caller)
    ), '[]'::jsonb)
  );
end; $$;

revoke all on function public.list_trust_network(uuid) from public, anon;
grant execute on function public.list_trust_network(uuid) to authenticated, service_role;
