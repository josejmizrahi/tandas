-- R.7.B — Governance Orchestration: alias resolution + data-driven policy + new entrypoint with idempotency
-- Doctrine: Plans/Active/R7_GovernanceOrchestrationEngine.md §4 (camino A firmado)
-- Preserva: request_governed_action() / _governance_action_approved() interface
-- DoD: legacy + canonical action_keys → same policy_key; idempotency replay; PULL consumers backwards compat

-- §1 — Alias resolver (canonical from any input)
create or replace function public._governance_action_resolve(p_action_key text)
returns text language sql stable as $$
  select coalesce(
    (select action_key from public.governance_action_catalog
      where action_key = p_action_key
         or p_action_key = any(legacy_aliases)
      limit 1),
    p_action_key
  );
$$;

comment on function public._governance_action_resolve(text) is
  'R.7.B — Resuelve action_key (cualquier alias R.5 o canonical R.7) a su forma canonical via governance_action_catalog. Fallback: devuelve input as-is si no esta en catalog.';

-- §2 — Rewrite _governance_action_policy_key data-driven (backwards compat con R.5 hardcoded)
-- IMMUTABLE → STABLE (ahora lee tabla). Verificado: R.5 no lo usa en indexes/generated cols.
create or replace function public._governance_action_policy_key(p_action_key text)
returns text language sql stable as $$
  with resolved as (
    select public._governance_action_resolve(p_action_key) as canonical_key
  )
  select coalesce(
    (select gac.policy_key
       from public.governance_action_catalog gac, resolved
      where gac.action_key = resolved.canonical_key
        and gac.policy_key is not null),
    (select canonical_key || '_requires_vote' from resolved)
  );
$$;

comment on function public._governance_action_policy_key(text) is
  'R.7.B rewrite — data-driven via governance_action_catalog. Backwards compat: los 5 hardcoded mappings R.5 (member_ban/resource_transfer/large_expense/rule_change/ownership_change) estan seedados como rows en catalog con sus policy_keys originales.';

-- §3 — _governance_action_approved alias-aware (PULL consumers backwards compat)
-- Rewrite: resuelve caller's p_action_key y row's action_key a canonical antes de comparar.
create or replace function public._governance_action_approved(
  p_context_actor_id uuid,
  p_action_key text,
  p_target_id uuid
) returns uuid language sql stable security definer set search_path to public as $$
  with resolved as (
    select public._governance_action_resolve(p_action_key) as canonical_key
  )
  select ga.id
    from public.governance_actions ga
    join public.decisions d on d.id = ga.decision_id
    cross join resolved
   where ga.context_actor_id = p_context_actor_id
     and public._governance_action_resolve(ga.action_key) = resolved.canonical_key
     and (p_target_id is null or ga.target_id = p_target_id)
     and ga.status in ('proposed', 'approved')
     and d.status in ('approved', 'executed')
   order by d.decided_at desc nulls last
   limit 1;
$$;

comment on function public._governance_action_approved(uuid, text, uuid) is
  'R.7.B rewrite — alias-aware. Resuelve caller key y row key a canonical antes de comparar. Permite que rows legacy (action_key=remove_member) Y nuevas (action_key=member.remove) sean encontradas desde cualquier alias.';

-- §4 — request_governance_action (new canonical entrypoint with idempotency)
create or replace function public.request_governance_action(
  p_context_actor_id uuid,
  p_action_key text,
  p_target_type text default null,
  p_target_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_title text default null,
  p_closes_at timestamptz default null,
  p_client_id text default null
) returns jsonb
language plpgsql security definer set search_path to public, auth as $$
declare
  v_canonical_key text;
  v_idempotency_key text;
  v_lock_key bigint;
  v_existing public.governance_actions%rowtype;
  v_result jsonb;
  v_ga_id uuid;
begin
  -- Resolve alias → canonical
  v_canonical_key := public._governance_action_resolve(p_action_key);

  -- Idempotency: if client_id provided, compute key and check for replay under advisory lock
  if p_client_id is not null then
    v_idempotency_key := encode(extensions.digest(
      v_canonical_key
      || '|' || p_context_actor_id::text
      || '|' || coalesce(p_target_id::text, '')
      || '|' || p_client_id,
      'sha1'
    ), 'hex');

    v_lock_key := hashtext(v_idempotency_key)::bigint;
    perform pg_advisory_xact_lock(v_lock_key);

    select * into v_existing
    from public.governance_actions
    where idempotency_key = v_idempotency_key
    limit 1;

    if found then
      return jsonb_build_object(
        'requires_decision', v_existing.requires_decision,
        'governance_action_id', v_existing.id,
        'decision_id', v_existing.decision_id,
        'action_key', v_existing.action_key,
        'status', v_existing.status,
        'idempotent_replay', true
      );
    end if;
  end if;

  -- Delegate to R.5 entrypoint with canonical key (storage uses canonical going forward)
  v_result := public.request_governed_action(
    p_context_actor_id := p_context_actor_id,
    p_action_key := v_canonical_key,
    p_target_type := p_target_type,
    p_target_id := p_target_id,
    p_payload := p_payload,
    p_title := p_title,
    p_closes_at := p_closes_at
  );

  v_ga_id := (v_result->>'governance_action_id')::uuid;

  -- Stamp idempotency on the newly created row
  if p_client_id is not null and v_ga_id is not null then
    update public.governance_actions
       set idempotency_key = v_idempotency_key,
           client_id = p_client_id
     where id = v_ga_id;
  end if;

  return v_result || jsonb_build_object('idempotent_replay', false);
end;
$$;

grant execute on function public.request_governance_action(uuid, text, text, uuid, jsonb, text, timestamptz, text)
  to authenticated;

comment on function public.request_governance_action(uuid, text, text, uuid, jsonb, text, timestamptz, text) is
  'R.7.B — Canonical entrypoint. Resuelve aliases, calcula idempotency_key sha1 si client_id presente, advisory lock para race-safe, delega a request_governed_action() con canonical key. Storage: action_key canonical. PULL consumers (remove_member, etc.) backwards compat via _governance_action_approved alias-aware.';
