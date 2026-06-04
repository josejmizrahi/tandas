-- ============================================================================
-- R.5 · GOVERNANCE ENGINE
-- ============================================================================
-- Convierte las decisiones en el mecanismo oficial de autoridad. Todo additive
-- y backward-compatible: contextos sin políticas se comportan EXACTAMENTE igual
-- que antes (peso de voto = 1, sin gates, sin quórum). El engine sólo "despierta"
-- cuando un contexto define governance_policies.
--
-- Entregables R.5:
--   5.1 governance_policies        (políticas por contexto: key -> value jsonb)
--   5.2 vote_delegations           (delego mi voto en otra persona hasta X fecha)
--   5.3 weighted voting            (peso por igualdad / ownership / participación / shares)
--   5.4 consent voting             ("no objections" => aprobado)
--   5.5 governance_actions         (auditoría: quién propuso / aprobó / ejecutó)
--   5.6 mandatory governance       (acciones críticas => decision required, opt-in)
--
-- RPCs canónicas:
--   create_governance_policy · update_governance_policy · list_governance_policies
--   delegate_vote · revoke_vote_delegation · request_governed_action
--
-- NOTA: no se renombra ni se rompe ninguna RPC existente. vote_decision NO se
-- toca (su auto-finalize por mayoría sigue igual); el peso de voto se inyecta
-- vía trigger BEFORE INSERT/UPDATE en decision_votes (default -> 1). El quórum,
-- el umbral de aprobación y el consent se aplican SÓLO en close_decision y SÓLO
-- cuando el contexto tiene la política correspondiente.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 5.1 governance_policies
-- ────────────────────────────────────────────────────────────────────────────
create table if not exists public.governance_policies (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  policy_key text not null,
  policy_value jsonb not null,
  created_by_actor_id uuid references public.actors(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (context_actor_id, policy_key)
);

create index if not exists idx_governance_policies_context
  on public.governance_policies (context_actor_id);

drop trigger if exists trg_governance_policies_touch on public.governance_policies;
create trigger trg_governance_policies_touch before update on public.governance_policies
  for each row execute function public.touch_updated_at();

comment on table public.governance_policies is
  'R.5.1: políticas de gobernanza por contexto (key -> value jsonb). Ej: '
  '"expense_threshold"->5000, "member_ban_requires_vote"->true, "quorum"->0.5, '
  '"approval_threshold"->0.66, "consent_voting"->true, '
  '"vote_weight_source"->{"source":"shares","shares":{...}}.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5.2 vote_delegations
-- ────────────────────────────────────────────────────────────────────────────
create table if not exists public.vote_delegations (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  delegator_actor_id uuid not null references public.actors(id),
  delegate_actor_id uuid not null references public.actors(id),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (delegator_actor_id <> delegate_actor_id)
);

-- una delegación activa por (contexto, delegador)
create unique index if not exists idx_vote_delegations_active
  on public.vote_delegations (context_actor_id, delegator_actor_id)
  where revoked_at is null;

create index if not exists idx_vote_delegations_delegate
  on public.vote_delegations (context_actor_id, delegate_actor_id)
  where revoked_at is null;

comment on table public.vote_delegations is
  'R.5.2: delego mi voto (delegator) en otra persona (delegate) en un contexto, '
  'opcionalmente hasta ends_at. El peso delegado se suma al delegate mientras el '
  'delegador no vote por sí mismo en esa decisión.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5.5 governance_actions (auditoría + enlace acción crítica <-> decisión)
-- ────────────────────────────────────────────────────────────────────────────
create table if not exists public.governance_actions (
  id uuid primary key default gen_random_uuid(),
  context_actor_id uuid not null references public.actors(id) on delete cascade,
  action_key text not null,
  target_type text,
  target_id uuid,
  payload jsonb not null default '{}',
  requires_decision boolean not null default false,
  decision_id uuid references public.decisions(id) on delete set null,
  status text not null default 'proposed'
    check (status in ('not_required', 'proposed', 'approved', 'rejected', 'executed', 'cancelled')),
  proposed_by_actor_id uuid references public.actors(id),
  executed_by_actor_id uuid references public.actors(id),
  executed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_governance_actions_context
  on public.governance_actions (context_actor_id, action_key);
create index if not exists idx_governance_actions_target
  on public.governance_actions (context_actor_id, action_key, target_id);
create index if not exists idx_governance_actions_decision
  on public.governance_actions (decision_id) where decision_id is not null;

drop trigger if exists trg_governance_actions_touch on public.governance_actions;
create trigger trg_governance_actions_touch before update on public.governance_actions
  for each row execute function public.touch_updated_at();

comment on table public.governance_actions is
  'R.5.5/5.6: una acción crítica (ban, transfer, large_expense, rule_change, '
  'ownership_change…) y la decisión que la gobierna. Auditoría de quién propuso '
  '(proposed_by) / aprobó (decision_id -> decision_votes) / ejecutó (executed_by).';

-- ────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ────────────────────────────────────────────────────────────────────────────

-- governance_policy(context, key) -> value jsonb (o null si no existe)
create or replace function public.governance_policy(p_context_actor_id uuid, p_policy_key text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select policy_value from public.governance_policies
   where context_actor_id = p_context_actor_id and policy_key = p_policy_key;
$$;

revoke all on function public.governance_policy(uuid, text) from public, anon;
grant execute on function public.governance_policy(uuid, text) to authenticated, service_role;

-- _governance_action_policy_key(action_key) -> policy_key que la gobierna
create or replace function public._governance_action_policy_key(p_action_key text)
returns text
language sql immutable
as $$
  select case p_action_key
    when 'ban_member'       then 'member_ban_requires_vote'
    when 'member_ban'       then 'member_ban_requires_vote'
    when 'remove_member'    then 'member_ban_requires_vote'
    when 'resource_transfer' then 'resource_transfer_requires_vote'
    when 'resource_sale'    then 'resource_transfer_requires_vote'
    when 'large_expense'    then 'large_expense_requires_vote'
    when 'rule_change'      then 'rule_change_requires_vote'
    when 'ownership_change' then 'ownership_change_requires_vote'
    else p_action_key || '_requires_vote'
  end;
$$;

-- actor_vote_weight(context, actor, policy) -> peso del actor según la fuente
-- Fuentes (policy = {"source": "...", ...}): equal | shares | ownership | participation.
-- Default / policy null -> 1 (comportamiento histórico).
create or replace function public.actor_vote_weight(
  p_context_actor_id uuid,
  p_actor_id uuid,
  p_policy jsonb default null
)
returns numeric
language plpgsql stable security definer set search_path = public
as $$
declare
  v_source text := coalesce(p_policy->>'source', 'equal');
  v_w numeric;
begin
  if v_source = 'shares' then
    v_w := coalesce(
      (p_policy->'shares'->>p_actor_id::text)::numeric,
      (select (am.metadata->>'shares')::numeric from public.actor_memberships am
        where am.context_actor_id = p_context_actor_id and am.member_actor_id = p_actor_id
          and am.membership_status = 'active'),
      1);
  elsif v_source = 'ownership' then
    v_w := coalesce(
      (p_policy->'ownership'->>p_actor_id::text)::numeric,
      (select (am.metadata->>'ownership_weight')::numeric from public.actor_memberships am
        where am.context_actor_id = p_context_actor_id and am.member_actor_id = p_actor_id
          and am.membership_status = 'active'),
      1);
  elsif v_source = 'participation' then
    v_w := greatest((
      select count(*) from public.event_participants ep
        join public.calendar_events ce on ce.id = ep.event_id
       where ce.context_actor_id = p_context_actor_id
         and ep.participant_actor_id = p_actor_id
         and ep.checked_in_at is not null), 1);
  else
    v_w := 1;
  end if;
  return greatest(coalesce(v_w, 1), 0);
end;
$$;

revoke all on function public.actor_vote_weight(uuid, uuid, jsonb) from public, anon;
grant execute on function public.actor_vote_weight(uuid, uuid, jsonb) to authenticated, service_role;

-- _effective_vote_weight(decision, voter) -> peso propio + peso delegado (5.2 + 5.3)
create or replace function public._effective_vote_weight(p_decision_id uuid, p_voter_actor_id uuid)
returns numeric
language plpgsql stable security definer set search_path = public
as $$
declare
  v_context uuid;
  v_policy jsonb;
  v_own numeric;
  v_delegated numeric;
begin
  select context_actor_id into v_context from public.decisions where id = p_decision_id;
  if v_context is null then return 1; end if;

  v_policy := public.governance_policy(v_context, 'vote_weight_source');
  v_own := public.actor_vote_weight(v_context, p_voter_actor_id, v_policy);

  select coalesce(sum(public.actor_vote_weight(v_context, d.delegator_actor_id, v_policy)), 0)
    into v_delegated
    from public.vote_delegations d
   where d.context_actor_id = v_context
     and d.delegate_actor_id = p_voter_actor_id
     and d.revoked_at is null
     and (d.starts_at is null or d.starts_at <= now())
     and (d.ends_at is null or d.ends_at > now())
     and not exists (
       select 1 from public.decision_votes dv
        where dv.decision_id = p_decision_id and dv.voter_actor_id = d.delegator_actor_id);

  return v_own + coalesce(v_delegated, 0);
end;
$$;

revoke all on function public._effective_vote_weight(uuid, uuid) from public, anon;
grant execute on function public._effective_vote_weight(uuid, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.3 weighted voting — trigger que inyecta el peso al votar (additive, default 1)
-- ────────────────────────────────────────────────────────────────────────────
create or replace function public._apply_vote_weight()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  new.weight := public._effective_vote_weight(new.decision_id, new.voter_actor_id);
  return new;
end;
$$;

drop trigger if exists trg_decision_votes_weight on public.decision_votes;
create trigger trg_decision_votes_weight
  before insert or update of voter_actor_id, decision_id on public.decision_votes
  for each row execute function public._apply_vote_weight();

comment on function public._apply_vote_weight() is
  'R.5.3: calcula el peso del voto (propio + delegado) al insertar/actualizar. '
  'Contextos sin política de pesos ni delegaciones -> 1 (sin cambio de conducta).';

-- ────────────────────────────────────────────────────────────────────────────
-- RLS
-- ────────────────────────────────────────────────────────────────────────────
alter table public.governance_policies enable row level security;
alter table public.vote_delegations enable row level security;
alter table public.governance_actions enable row level security;

drop policy if exists governance_policies_select on public.governance_policies;
create policy governance_policies_select on public.governance_policies
  for select to authenticated using (public.is_context_member(context_actor_id));

drop policy if exists vote_delegations_select on public.vote_delegations;
create policy vote_delegations_select on public.vote_delegations
  for select to authenticated using (public.is_context_member(context_actor_id));

drop policy if exists governance_actions_select on public.governance_actions;
create policy governance_actions_select on public.governance_actions
  for select to authenticated using (public.is_context_member(context_actor_id));

revoke all on public.governance_policies, public.vote_delegations, public.governance_actions from anon;

-- ────────────────────────────────────────────────────────────────────────────
-- RPCs
-- ────────────────────────────────────────────────────────────────────────────

-- create_governance_policy / update_governance_policy (ambas upsert; value null borra)
create or replace function public.create_governance_policy(
  p_context_actor_id uuid,
  p_policy_key text,
  p_policy_value jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to set governance policies in context %', p_context_actor_id using errcode = '42501';
  end if;
  if p_policy_key is null or btrim(p_policy_key) = '' then
    raise exception 'policy_key required' using errcode = '22023';
  end if;

  if p_policy_value is null then
    delete from public.governance_policies
     where context_actor_id = p_context_actor_id and policy_key = p_policy_key;
    perform public._emit_activity(p_context_actor_id, v_caller, 'governance.policy_removed',
      'governance_policy', null, jsonb_build_object('policy_key', p_policy_key));
    return jsonb_build_object('context_actor_id', p_context_actor_id, 'policy_key', p_policy_key, 'removed', true);
  end if;

  insert into public.governance_policies (context_actor_id, policy_key, policy_value, created_by_actor_id)
  values (p_context_actor_id, btrim(p_policy_key), p_policy_value, v_caller)
  on conflict (context_actor_id, policy_key)
  do update set policy_value = excluded.policy_value, updated_at = now()
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'governance.policy_set',
    'governance_policy', v_id, jsonb_build_object('policy_key', btrim(p_policy_key), 'policy_value', p_policy_value));

  return jsonb_build_object('policy_id', v_id, 'context_actor_id', p_context_actor_id,
    'policy_key', btrim(p_policy_key), 'policy_value', p_policy_value);
end;
$$;

revoke all on function public.create_governance_policy(uuid, text, jsonb) from public, anon;
grant execute on function public.create_governance_policy(uuid, text, jsonb) to authenticated, service_role;

create or replace function public.update_governance_policy(
  p_context_actor_id uuid,
  p_policy_key text,
  p_policy_value jsonb
)
returns jsonb
language sql security definer set search_path = public, auth
as $$
  select public.create_governance_policy(p_context_actor_id, p_policy_key, p_policy_value);
$$;

revoke all on function public.update_governance_policy(uuid, text, jsonb) from public, anon;
grant execute on function public.update_governance_policy(uuid, text, jsonb) to authenticated, service_role;

-- list_governance_policies(context) -> [{policy_key, policy_value, updated_at}]
create or replace function public.list_governance_policies(p_context_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'policy_key', policy_key, 'policy_value', policy_value, 'updated_at', updated_at)
      order by policy_key)
    from public.governance_policies where context_actor_id = p_context_actor_id), '[]'::jsonb);
end;
$$;

revoke all on function public.list_governance_policies(uuid) from public, anon;
grant execute on function public.list_governance_policies(uuid) to authenticated, service_role;

-- delegate_vote(context, delegate, ends_at) — el caller delega su voto
create or replace function public.delegate_vote(
  p_context_actor_id uuid,
  p_delegate_actor_id uuid,
  p_ends_at timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_id uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if p_delegate_actor_id = v_caller then
    raise exception 'cannot delegate your vote to yourself' using errcode = '22023';
  end if;
  if not public.is_context_member(p_context_actor_id) then
    raise exception 'not a member of context %', p_context_actor_id using errcode = '42501';
  end if;
  if not exists (select 1 from public.actor_memberships
                 where context_actor_id = p_context_actor_id
                   and member_actor_id = p_delegate_actor_id
                   and membership_status = 'active') then
    raise exception 'delegate is not an active member of the context' using errcode = '22023';
  end if;

  -- revoca delegación previa activa del caller en este contexto
  update public.vote_delegations set revoked_at = now()
   where context_actor_id = p_context_actor_id and delegator_actor_id = v_caller and revoked_at is null;

  insert into public.vote_delegations
    (context_actor_id, delegator_actor_id, delegate_actor_id, ends_at)
  values (p_context_actor_id, v_caller, p_delegate_actor_id, p_ends_at)
  returning id into v_id;

  perform public._emit_activity(p_context_actor_id, v_caller, 'governance.vote_delegated',
    'vote_delegation', v_id, jsonb_strip_nulls(jsonb_build_object(
      'delegate_actor_id', p_delegate_actor_id, 'ends_at', p_ends_at)));

  return jsonb_build_object('delegation_id', v_id, 'context_actor_id', p_context_actor_id,
    'delegate_actor_id', p_delegate_actor_id, 'ends_at', p_ends_at);
end;
$$;

revoke all on function public.delegate_vote(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.delegate_vote(uuid, uuid, timestamptz) to authenticated, service_role;

-- revoke_vote_delegation(context) — el caller revoca su delegación activa
create or replace function public.revoke_vote_delegation(p_context_actor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_count int;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  update public.vote_delegations set revoked_at = now()
   where context_actor_id = p_context_actor_id and delegator_actor_id = v_caller and revoked_at is null;
  get diagnostics v_count = row_count;
  if v_count > 0 then
    perform public._emit_activity(p_context_actor_id, v_caller, 'governance.delegation_revoked',
      'vote_delegation', null, '{}'::jsonb);
  end if;
  return jsonb_build_object('revoked', v_count > 0, 'count', v_count);
end;
$$;

revoke all on function public.revoke_vote_delegation(uuid) from public, anon;
grant execute on function public.revoke_vote_delegation(uuid) to authenticated, service_role;

-- request_governed_action — 5.6: ¿esta acción crítica requiere decisión?
-- Si la política lo exige, abre una decisión 'governance' y registra la
-- governance_action 'proposed'. Si no, registra 'not_required' y el caller procede.
create or replace function public.request_governed_action(
  p_context_actor_id uuid,
  p_action_key text,
  p_target_type text default null,
  p_target_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_title text default null,
  p_closes_at timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_policy_key text := public._governance_action_policy_key(p_action_key);
  v_requires boolean;
  v_decision uuid;
  v_ga uuid;
  v_title text := coalesce(nullif(btrim(coalesce(p_title, '')), ''), 'Acción de gobernanza: ' || p_action_key);
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'decisions.create') then
    raise exception 'not authorized to propose governed actions in context %', p_context_actor_id using errcode = '42501';
  end if;

  v_requires := public.governance_policy(p_context_actor_id, v_policy_key) = 'true'::jsonb;

  if not v_requires then
    insert into public.governance_actions
      (context_actor_id, action_key, target_type, target_id, payload, requires_decision, status, proposed_by_actor_id)
    values (p_context_actor_id, p_action_key, p_target_type, p_target_id,
            coalesce(p_payload, '{}'::jsonb), false, 'not_required', v_caller)
    returning id into v_ga;
    return jsonb_build_object('requires_decision', false, 'governance_action_id', v_ga, 'action_key', p_action_key);
  end if;

  v_decision := (public.create_decision(
    p_context_actor_id, 'governance', v_title,
    p_payload := jsonb_strip_nulls(coalesce(p_payload, '{}'::jsonb) || jsonb_build_object(
      'governed_action', p_action_key, 'target_type', p_target_type, 'target_id', p_target_id)),
    p_closes_at := p_closes_at))->>'decision_id';

  insert into public.governance_actions
    (context_actor_id, action_key, target_type, target_id, payload, requires_decision, decision_id, status, proposed_by_actor_id)
  values (p_context_actor_id, p_action_key, p_target_type, p_target_id,
          coalesce(p_payload, '{}'::jsonb), true, v_decision, 'proposed', v_caller)
  returning id into v_ga;

  perform public._emit_activity(p_context_actor_id, v_caller, 'governance.action_requested',
    'governance_action', v_ga, jsonb_strip_nulls(jsonb_build_object(
      'action_key', p_action_key, 'target_type', p_target_type, 'target_id', p_target_id,
      'decision_id', v_decision)), p_decision_id := v_decision::uuid);

  return jsonb_build_object('requires_decision', true, 'governance_action_id', v_ga,
    'decision_id', v_decision, 'action_key', p_action_key);
end;
$$;

revoke all on function public.request_governed_action(uuid, text, text, uuid, jsonb, text, timestamptz) from public, anon;
grant execute on function public.request_governed_action(uuid, text, text, uuid, jsonb, text, timestamptz) to authenticated, service_role;

-- _governance_action_approved(context, action_key, target) -> governance_action id
-- aprobada (decisión linkeada approved/executed). Source of truth: decisions.
create or replace function public._governance_action_approved(
  p_context_actor_id uuid,
  p_action_key text,
  p_target_id uuid
)
returns uuid
language sql stable security definer set search_path = public
as $$
  select ga.id
    from public.governance_actions ga
    join public.decisions d on d.id = ga.decision_id
   where ga.context_actor_id = p_context_actor_id
     and ga.action_key = p_action_key
     and (p_target_id is null or ga.target_id = p_target_id)
     and ga.status in ('proposed', 'approved')
     and d.status in ('approved', 'executed')
   order by d.decided_at desc nulls last
   limit 1;
$$;

revoke all on function public._governance_action_approved(uuid, text, uuid) from public, anon;
grant execute on function public._governance_action_approved(uuid, text, uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.4 consent voting + quórum + umbral de aprobación en close_decision
-- ────────────────────────────────────────────────────────────────────────────
-- Recreación backward-compatible: la rama de gobernanza SÓLO se activa para
-- modelos no-single_choice cuando el contexto define alguna de las políticas
-- quorum / approval_threshold / consent_voting. En cualquier otro caso, el
-- comportamiento es IDÉNTICO al de la versión previa.
create or replace function public.close_decision(p_decision_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_members numeric;
  v_member_weight numeric;
  v_approve numeric;
  v_reject numeric;
  v_total numeric;
  v_option_tally jsonb;
  v_winning_option text;
  v_winning_option_id uuid;
  v_new_status text;
  v_quorum jsonb;
  v_threshold jsonb;
  v_consent jsonb;
  v_governance boolean := false;
  v_quorum_met boolean := true;
  v_result jsonb;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;
  if not public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute') then
    raise exception 'not authorized to close decisions' using errcode = '42501';
  end if;

  if v_d.status <> 'open' then
    return jsonb_build_object('decision_id', p_decision_id, 'status', v_d.status,
      'winning_option', v_d.result->>'winning_option',
      'winning_option_id', v_d.result->>'winning_option_id',
      'already_closed', true);
  end if;

  select count(*) into v_members from public.actor_memberships
   where context_actor_id = v_d.context_actor_id and membership_status = 'active';
  v_members := greatest(v_members, 1);

  select coalesce(sum(weight) filter (where vote = 'approve'), 0),
         coalesce(sum(weight) filter (where vote = 'reject'), 0),
         coalesce(sum(weight), 0)
    into v_approve, v_reject, v_total
    from public.decision_votes where decision_id = p_decision_id;

  v_quorum    := public.governance_policy(v_d.context_actor_id, 'quorum');
  v_threshold := public.governance_policy(v_d.context_actor_id, 'approval_threshold');
  v_consent   := public.governance_policy(v_d.context_actor_id, 'consent_voting');
  v_governance := (v_quorum is not null or v_threshold is not null or v_consent = 'true'::jsonb)
                  and v_d.voting_model <> 'single_choice';

  if v_d.voting_model = 'single_choice' then
    select coalesce(jsonb_object_agg(opt, votes), '{}'::jsonb) into v_option_tally
    from (
      select coalesce(o.option_key, dv.metadata->>'option') as opt, sum(dv.weight) as votes
        from public.decision_votes dv
        left join public.decision_options o on o.id = dv.option_id
       where dv.decision_id = p_decision_id
         and coalesce(o.option_key, dv.metadata->>'option') is not null
       group by coalesce(o.option_key, dv.metadata->>'option')
    ) t;

    select opt into v_winning_option
    from (
      select coalesce(o.option_key, dv.metadata->>'option') as opt, sum(dv.weight) as votes
        from public.decision_votes dv
        left join public.decision_options o on o.id = dv.option_id
       where dv.decision_id = p_decision_id
         and coalesce(o.option_key, dv.metadata->>'option') is not null
       group by coalesce(o.option_key, dv.metadata->>'option')
       order by sum(dv.weight) desc limit 1
    ) w;

    if v_winning_option is not null then
      select id into v_winning_option_id from public.decision_options
       where decision_id = p_decision_id and option_key = v_winning_option;
    end if;
    v_new_status := case when v_winning_option is not null then 'approved' else 'rejected' end;

  elsif v_governance then
    -- quórum: peso votante / peso total de miembros activos
    if v_quorum is not null then
      select coalesce(sum(public.actor_vote_weight(v_d.context_actor_id, am.member_actor_id,
               public.governance_policy(v_d.context_actor_id, 'vote_weight_source'))), v_members)
        into v_member_weight
        from public.actor_memberships am
       where am.context_actor_id = v_d.context_actor_id and am.membership_status = 'active';
      v_member_weight := greatest(v_member_weight, 1);
      v_quorum_met := v_total >= (v_quorum::text)::numeric * v_member_weight;
    end if;

    if not v_quorum_met then
      v_new_status := 'rejected';
    elsif v_consent = 'true'::jsonb then
      -- consent: aprobado salvo objeción (algún reject)
      v_new_status := case when v_reject = 0 then 'approved' else 'rejected' end;
    elsif v_threshold is not null then
      v_new_status := case
        when (v_approve + v_reject) > 0
         and v_approve / (v_approve + v_reject) >= (v_threshold::text)::numeric
        then 'approved' else 'rejected' end;
    else
      v_new_status := case when v_approve > v_reject and v_approve > 0 then 'approved' else 'rejected' end;
    end if;

    select id, option_key into v_winning_option_id, v_winning_option
      from public.decision_options where decision_id = p_decision_id
        and option_key = case when v_new_status = 'approved' then 'approve' else 'reject' end;

  else
    v_new_status := case when v_approve > v_reject and v_approve > 0 then 'approved' else 'rejected' end;
    select id, option_key into v_winning_option_id, v_winning_option
      from public.decision_options where decision_id = p_decision_id
        and option_key = case when v_new_status = 'approved' then 'approve' else 'reject' end;
  end if;

  v_result := jsonb_strip_nulls(jsonb_build_object(
    'approve', v_approve, 'reject', v_reject, 'members', v_members, 'total_weight', v_total,
    'option_tally', v_option_tally,
    'winning_option', v_winning_option,
    'winning_option_id', v_winning_option_id,
    'governance', case when v_governance then jsonb_strip_nulls(jsonb_build_object(
      'quorum', v_quorum, 'approval_threshold', v_threshold, 'consent', v_consent,
      'quorum_met', v_quorum_met)) else null end));

  update public.decisions
     set status = v_new_status, decided_at = now(), closes_at = coalesce(closes_at, now()),
         result = v_result
   where id = p_decision_id;

  -- 5.5: si esta decisión gobierna una acción crítica, refleja el resultado en la auditoría
  update public.governance_actions
     set status = case when v_new_status = 'approved' then 'approved' else 'rejected' end
   where decision_id = p_decision_id and status = 'proposed';

  perform public._emit_activity(v_d.context_actor_id, v_caller, 'decision.closed', 'decision', p_decision_id,
    jsonb_strip_nulls(jsonb_build_object(
      'status', v_new_status, 'winning_option', v_winning_option,
      'winning_option_id', v_winning_option_id, 'closed_by', 'explicit_close')),
    p_decision_id := p_decision_id);

  return jsonb_build_object('decision_id', p_decision_id, 'status', v_new_status,
    'winning_option', v_winning_option, 'winning_option_id', v_winning_option_id,
    'tally', v_result);
end;
$$;

revoke all on function public.close_decision(uuid) from public, anon;
grant execute on function public.close_decision(uuid) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5.6 mandatory governance — gate en remove_member (opt-in; default sin cambio)
-- ────────────────────────────────────────────────────────────────────────────
-- Si el contexto define member_ban_requires_vote=true, remove_member exige una
-- decisión de gobernanza aprobada para ese miembro (creada vía
-- request_governed_action). Sin la política, conducta histórica intacta.
create or replace function public.remove_member(
  p_context_actor_id uuid,
  p_member_actor_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ga uuid;
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;
  if not public.has_actor_authority(p_context_actor_id, v_caller, 'members.manage') then
    raise exception 'not authorized to remove members' using errcode = '42501';
  end if;
  if p_member_actor_id = v_caller then
    raise exception 'use leave_context to remove yourself' using errcode = '22023';
  end if;

  -- Mandatory governance (5.6): si la política lo exige, requiere decisión aprobada
  if public.governance_policy(p_context_actor_id, 'member_ban_requires_vote') = 'true'::jsonb then
    v_ga := public._governance_action_approved(p_context_actor_id, 'member_ban', p_member_actor_id);
    if v_ga is null then
      raise exception 'governance_required: removing a member requires an approved decision in this context'
        using errcode = '42501',
        hint = 'call request_governed_action(context, ''member_ban'', ''actor'', member_id) and get it approved first';
    end if;
  end if;

  update public.actor_memberships
     set membership_status = 'removed', left_at = now(),
         metadata = metadata || jsonb_strip_nulls(jsonb_build_object('removed_by', v_caller, 'reason', p_reason))
   where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id
     and membership_status in ('active', 'invited', 'paused');

  update public.role_assignments set ends_at = now()
   where context_actor_id = p_context_actor_id and member_actor_id = p_member_actor_id and ends_at is null;

  -- cierra la auditoría de la acción de gobernanza
  if v_ga is not null then
    update public.governance_actions
       set status = 'executed', executed_by_actor_id = v_caller, executed_at = now()
     where id = v_ga;
  end if;

  perform public._emit_activity(p_context_actor_id, v_caller, 'member.removed', 'actor', p_member_actor_id,
    jsonb_strip_nulls(jsonb_build_object('reason', p_reason, 'governance_action_id', v_ga)));

  return jsonb_build_object('removed', true, 'governance_action_id', v_ga);
end;
$$;

revoke all on function public.remove_member(uuid, uuid, text) from public, anon;
grant execute on function public.remove_member(uuid, uuid, text) to authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- Catálogo de actividad (R.2S.8): nuevos event_types de gobernanza
-- ────────────────────────────────────────────────────────────────────────────
insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('governance.policy_set',        'governance', 'Se definió una política de gobernanza', 'governance_policy', false),
  ('governance.policy_removed',    'governance', 'Se eliminó una política de gobernanza', 'governance_policy', false),
  ('governance.vote_delegated',    'governance', 'Un actor delegó su voto',               'vote_delegation',   false),
  ('governance.delegation_revoked','governance', 'Un actor revocó su delegación de voto', 'vote_delegation',   false),
  ('governance.action_requested',  'governance', 'Se propuso una acción de gobernanza',   'governance_action', false),
  ('governance.action_executed',   'governance', 'Se ejecutó una acción de gobernanza',   'governance_action', false)
on conflict (event_type) do nothing;
