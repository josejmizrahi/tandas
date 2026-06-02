-- ============================================================================
-- MVP 2.0 — M.7 DECISIONS
-- ============================================================================
-- NOTA orden: Decisions se ejecuta ANTES que Rules (el plan original era M.8)
-- porque obligations (creadas por consecuencias de rules) referencian decisions.
--
-- decisions + decision_votes + RPCs: create_decision / vote_decision (con
-- auto-finalize por mayoría absoluta) / execute_decision + RLS + smoke.
-- ============================================================================

create table public.decisions (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  decision_type text not null check (decision_type in
    ('expense_approval', 'rule_change', 'member_admission', 'resource_purchase', 'reservation_dispute', 'generic')),
  title text not null,
  description text,
  status text not null default 'open' check (status in
    ('open', 'approved', 'rejected', 'executed', 'cancelled')),
  created_by_actor_id uuid not null references public.actors(id),
  opens_at timestamptz default now(),
  closes_at timestamptz,
  decided_at timestamptz,
  executed_at timestamptz,
  payload jsonb not null default '{}',
  result jsonb not null default '{}',
  client_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_decisions_context on public.decisions (context_actor_id, status);
create unique index idx_decisions_client_id on public.decisions (context_actor_id, client_id) where client_id is not null;

create trigger trg_decisions_touch before update on public.decisions
  for each row execute function public.touch_updated_at();

create table public.decision_votes (
  id uuid primary key default gen_random_uuid(),
  decision_id uuid not null references public.decisions(id) on delete cascade,
  voter_actor_id uuid not null references public.actors(id),
  vote text not null check (vote in ('approve', 'reject', 'abstain')),
  weight numeric not null default 1,
  metadata jsonb not null default '{}',
  voted_at timestamptz not null default now(),
  unique (decision_id, voter_actor_id)
);

-- ────────────────────────────────────────────────────────────────────────────
-- RPCs
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public.create_decision(
  p_context_actor_id uuid,
  p_decision_type text,
  p_title text,
  p_description text default null,
  p_closes_at timestamptz default null,
  p_payload jsonb default '{}'::jsonb,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
  v_existing uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'decisions.create') then
    raise exception 'not authorized to create decisions in context %', p_context_actor_id using errcode = '42501';
  end if;

  if p_client_id is not null then
    select id into v_existing from public.decisions
     where context_actor_id = p_context_actor_id and client_id = p_client_id;
    if v_existing is not null then
      return jsonb_build_object('decision_id', v_existing,
        'decision', (select to_jsonb(d) from public.decisions d where d.id = v_existing));
    end if;
  end if;

  insert into public.decisions
    (context_actor_id, decision_type, title, description, created_by_actor_id, closes_at, payload, client_id)
  values
    (p_context_actor_id, p_decision_type, btrim(p_title), p_description, v_caller, p_closes_at,
     coalesce(p_payload, '{}'::jsonb), p_client_id)
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'decision.created', 'decision', v_id,
    jsonb_build_object('decision_type', p_decision_type, 'title', btrim(p_title)),
    p_decision_id := v_id);

  return jsonb_build_object('decision_id', v_id,
    'decision', (select to_jsonb(d) from public.decisions d where d.id = v_id));
end; $$;

revoke all on function public.create_decision(uuid, text, text, text, timestamptz, jsonb, text) from public, anon;
grant execute on function public.create_decision(uuid, text, text, text, timestamptz, jsonb, text) to authenticated, service_role;

-- vote_decision: con auto-finalize por mayoría absoluta de miembros activos
create or replace function public.vote_decision(p_decision_id uuid, p_vote text)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_members numeric;
  v_approve numeric;
  v_reject numeric;
  v_new_status text;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_vote not in ('approve', 'reject', 'abstain') then
    raise exception 'invalid vote: %', p_vote using errcode = '22023';
  end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.vote') then
    raise exception 'not authorized to vote in context %', v_d.context_actor_id using errcode = '42501';
  end if;
  if v_d.status <> 'open' then
    raise exception 'decision is %', v_d.status using errcode = '22023';
  end if;
  if v_d.closes_at is not null and v_d.closes_at <= now() then
    raise exception 'voting window closed' using errcode = '22023';
  end if;

  insert into public.decision_votes (decision_id, voter_actor_id, vote)
  values (p_decision_id, v_caller, p_vote)
  on conflict (decision_id, voter_actor_id)
  do update set vote = excluded.vote, voted_at = now();

  -- Auto-finalize: mayoría absoluta de miembros activos del contexto
  select count(*) into v_members from public.actor_memberships
   where context_actor_id = v_d.context_actor_id and membership_status = 'active';
  v_members := greatest(v_members, 1);

  select coalesce(sum(weight) filter (where vote = 'approve'), 0),
         coalesce(sum(weight) filter (where vote = 'reject'), 0)
    into v_approve, v_reject
    from public.decision_votes where decision_id = p_decision_id;

  if v_approve > v_members / 2.0 then
    v_new_status := 'approved';
  elsif v_reject >= v_members / 2.0 and v_reject > 0 and (v_members - v_reject) < v_members / 2.0 then
    -- imposible alcanzar mayoría de aprobación
    v_new_status := 'rejected';
  end if;

  if v_new_status is not null then
    update public.decisions
       set status = v_new_status, decided_at = now(),
           result = jsonb_build_object('approve', v_approve, 'reject', v_reject, 'members', v_members)
     where id = p_decision_id;

    perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.' || v_new_status, 'decision', p_decision_id,
      jsonb_build_object('approve', v_approve, 'reject', v_reject, 'members', v_members),
      p_decision_id := p_decision_id);
  end if;

  return jsonb_build_object(
    'decision_id', p_decision_id, 'my_vote', p_vote,
    'status', coalesce(v_new_status, 'open'),
    'tally', jsonb_build_object('approve', v_approve, 'reject', v_reject, 'members', v_members));
end; $$;

revoke all on function public.vote_decision(uuid, text) from public, anon;
grant execute on function public.vote_decision(uuid, text) to authenticated, service_role;

-- execute_decision: marca executed (los efectos específicos los cablea cada dominio)
create or replace function public.execute_decision(p_decision_id uuid, p_result jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to execute decisions' using errcode = '42501';
  end if;
  if v_d.status = 'executed' then
    return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed', 'already_executed', true);
  end if;
  if v_d.status <> 'approved' then
    raise exception 'only approved decisions can be executed (status: %)', v_d.status using errcode = '22023';
  end if;

  update public.decisions
     set status = 'executed', executed_at = now(),
         result = result || coalesce(p_result, '{}'::jsonb) || jsonb_build_object('executed_by_actor_id', v_caller)
   where id = p_decision_id;

  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.executed', 'decision', p_decision_id,
    coalesce(p_result, '{}'::jsonb), p_decision_id := p_decision_id);

  return jsonb_build_object('decision_id', p_decision_id, 'status', 'executed');
end; $$;

revoke all on function public.execute_decision(uuid, jsonb) from public, anon;
grant execute on function public.execute_decision(uuid, jsonb) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table public.decisions enable row level security;
alter table public.decision_votes enable row level security;

create policy decisions_select on public.decisions
  for select to authenticated
  using (public.is_context_member(context_actor_id));

create policy votes_select on public.decision_votes
  for select to authenticated
  using (
    voter_actor_id = public.current_actor_id()
    or exists (select 1 from public.decisions d
               where d.id = decision_votes.decision_id and public.is_context_member(d.context_actor_id))
  );

revoke all on public.decisions, public.decision_votes from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- Smoke
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_mvp2_m7_decisions()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_auth_c uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_c uuid; v_ctx uuid;
  v_result jsonb; v_decision uuid; v_code text;
  v_caught boolean;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke M7A', '+520000000014', null);
  v_b := public._create_person_actor_for_auth_user(v_auth_b, 'Smoke M7B', '+520000000015', null);
  v_c := public._create_person_actor_for_auth_user(v_auth_c, 'Smoke M7C', '+520000000016', null);

  -- Setup: contexto con 3 miembros
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_ctx := (public.create_context('_smoke_m7 Negocio', 'collective', 'project'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Caso 1: member crea decisión (gasto > umbral)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
  v_result := public.create_decision(v_ctx::uuid, 'expense_approval',
    '_smoke_m7 Comprar parrilla', p_payload := '{"amount": 25000, "currency": "MXN"}'::jsonb);
  v_decision := (v_result->>'decision_id')::uuid;
  if v_decision is null then raise exception 'mvp2_m7 Caso1: create_decision falló'; end if;

  -- Caso 2: votos — 1 de 3 no decide todavía
  v_result := public.vote_decision(v_decision, 'approve');
  if v_result->>'status' <> 'open' then
    raise exception 'mvp2_m7 Caso2: decisión cerrada prematuramente (1/3 votos)';
  end if;

  -- Caso 3: segundo approve (2 de 3) → mayoría absoluta → approved
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.vote_decision(v_decision, 'approve');
  if v_result->>'status' <> 'approved' then
    raise exception 'mvp2_m7 Caso3: mayoría no aprobó (status %)', v_result->>'status';
  end if;

  -- Caso 4: votar en decisión cerrada falla
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_c::text)::text, true);
  v_caught := false;
  begin
    perform public.vote_decision(v_decision, 'reject');
  exception when others then v_caught := true;
  end;
  if not v_caught then raise exception 'mvp2_m7 Caso4: se pudo votar en decisión cerrada'; end if;

  -- Caso 5: execute_decision por admin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.execute_decision(v_decision, '{"note": "comprada"}'::jsonb);
  if v_result->>'status' <> 'executed' then raise exception 'mvp2_m7 Caso5: execute falló'; end if;
  -- idempotente
  v_result := public.execute_decision(v_decision);
  if not (v_result->>'already_executed')::boolean then
    raise exception 'mvp2_m7 Caso5: execute no es idempotente';
  end if;

  -- Caso 6: member sin decisions.execute NO puede ejecutar
  declare v_d2 uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_d2 := (public.create_decision(v_ctx::uuid, 'generic', '_smoke_m7 Otra'))->>'decision_id';
    -- aprobar con 2 votos
    perform public.vote_decision(v_d2::uuid, 'approve');
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
    perform public.vote_decision(v_d2::uuid, 'approve');
    -- B (member) intenta ejecutar
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_b::text)::text, true);
    v_caught := false;
    begin
      perform public.execute_decision(v_d2::uuid);
    exception when insufficient_privilege then v_caught := true;
    end;
    if not v_caught then raise exception 'mvp2_m7 Caso6: member ejecutó sin autoridad'; end if;
  end;

  -- Cleanup
  perform set_config('request.jwt.claims', null, true);
  delete from public.decision_votes where decision_id in (select id from public.decisions where context_actor_id = v_ctx::uuid);
  delete from public.decisions where context_actor_id = v_ctx::uuid;
  delete from public.context_invites where context_actor_id = v_ctx::uuid;
  delete from public.role_assignments where context_actor_id = v_ctx::uuid;
  delete from public.role_permissions rp using public.roles r where r.id = rp.role_id and r.context_actor_id = v_ctx::uuid;
  delete from public.roles where context_actor_id = v_ctx::uuid;
  delete from public.actor_memberships where context_actor_id = v_ctx::uuid;
  delete from public.actors where id = v_ctx::uuid;
  delete from public.person_profiles where actor_id in (v_a, v_b, v_c);
  delete from public.actors where id in (v_a, v_b, v_c);
  delete from auth.users where id in (v_auth_a, v_auth_b, v_auth_c);

  raise notice '_smoke_mvp2_m7_decisions passed (6 casos)';
end; $$;

revoke all on function public._smoke_mvp2_m7_decisions() from public, anon, authenticated;

comment on function public._smoke_mvp2_m7_decisions() is 'Smoke MVP2 M.7: decisiones, votos, auto-finalize por mayoría, ejecución.';
