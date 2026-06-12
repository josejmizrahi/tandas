-- ────────────────────────────────────────────────────────────────────────────
-- FE.8 — política 'proportional' en pools (decisión founder 2026-06-12).
-- El CHECK de policy_key ya la permitía; faltaba la resolución. Semántica:
-- comparte materialización con equity_target (shares proporcionales al basis
-- persistidos en resolved_payload + settle de los aportes pending_pool, SIN
-- payout — la conversión a rights/nivelación queda DEFERRED a R.9 igual que
-- equity). Difieren en que proportional no tiene meta. preview expone
-- distribution='proportional_to_basis'.
-- ────────────────────────────────────────────────────────────────────────────

create or replace function public.preview_pool_resolution(p_pool_account_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_pool record;
  v_total numeric;
  v_cash_total numeric;
  v_stake_total numeric;
  v_asset_service_total numeric;
  v_entry_count int;
  v_money_currency_count int;
  v_payout_currency text;
  v_contributors jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select pa.* into v_pool from public.pool_accounts pa where pa.id = p_pool_account_id;
  if v_pool.id is null then
    raise exception 'pool_account not found: %', p_pool_account_id using errcode = '42704';
  end if;

  -- Gate de lectura: miembro del padre o contribuyente (espejo pool_account_detail)
  if not public.is_context_member(v_pool.parent_context_actor_id) then
    if not exists (
      select 1 from public.pool_basis_entries pbe
       where pbe.pool_account_id = v_pool.id and pbe.contributor_actor_id = v_caller
    ) then
      raise exception 'not authorized to preview pool resolution' using errcode = '42501';
    end if;
  end if;

  if v_pool.policy_key not in ('winner_takes_all', 'equity_target', 'proportional') then
    raise exception 'pool policy % resolution is not supported yet (winner_takes_all, equity_target, proportional)',
      v_pool.policy_key using errcode = '0A000';
  end if;

  -- Agregados del basis ledger
  select coalesce(sum(pbe.basis_amount), 0),
         coalesce(sum(pbe.basis_amount) filter (where pbe.basis_kind = 'cash'), 0),
         coalesce(sum(pbe.basis_amount) filter (where pbe.basis_kind = 'pending_stake'), 0),
         coalesce(sum(pbe.basis_amount) filter (where pbe.basis_kind in ('asset', 'service')), 0),
         count(*),
         count(distinct pbe.currency) filter (where pbe.basis_kind in ('cash', 'pending_stake')),
         min(pbe.currency) filter (where pbe.basis_kind in ('cash', 'pending_stake'))
    into v_total, v_cash_total, v_stake_total, v_asset_service_total,
         v_entry_count, v_money_currency_count, v_payout_currency
    from public.pool_basis_entries pbe
   where pbe.pool_account_id = v_pool.id;

  v_payout_currency := coalesce(v_pool.currency, v_payout_currency);

  -- Contribuyentes con share proporcional (basis / total). round(…,6) para wire.
  select coalesce(jsonb_agg(jsonb_build_object(
    'actor_id', c.contributor_actor_id,
    'display_name', a.display_name,
    'basis_amount', c.basis,
    'share', case when v_total > 0 then round(c.basis / v_total, 6) else 0 end
  ) order by c.basis desc, c.contributor_actor_id), '[]'::jsonb)
    into v_contributors
    from (
      select pbe.contributor_actor_id, sum(pbe.basis_amount) as basis
        from public.pool_basis_entries pbe
       where pbe.pool_account_id = v_pool.id
       group by pbe.contributor_actor_id
    ) c
    join public.actors a on a.id = c.contributor_actor_id;

  -- Warnings (preview NO raisea por estos: informa)
  if v_pool.status not in ('open', 'target_reached') then
    v_warnings := v_warnings || to_jsonb(format('pool is not resolvable in status %s', v_pool.status));
  end if;
  if v_entry_count = 0 then
    v_warnings := v_warnings || to_jsonb('no basis entries to resolve'::text);
  end if;
  if coalesce(v_money_currency_count, 0) > 1 then
    v_warnings := v_warnings || to_jsonb('mixed currencies across cash/pending_stake entries — resolve will reject'::text);
  end if;
  if v_pool.policy_key = 'winner_takes_all' and v_asset_service_total > 0 then
    v_warnings := v_warnings || to_jsonb('asset/service basis is excluded from the cash payout (manual transfer out of MVP scope)'::text);
  end if;

  v_result := jsonb_build_object(
    'pool_account_id', v_pool.id,
    'policy_key', v_pool.policy_key,
    'resolution_kind', v_pool.policy_key,
    'status', v_pool.status,
    'total_basis', v_total,
    'currency', v_payout_currency,
    'entry_count', v_entry_count,
    'contributors', v_contributors,
    'warnings', v_warnings
  );

  if v_pool.policy_key = 'winner_takes_all' then
    -- El winner se decide al momento de resolver (no en preview)
    v_result := v_result || jsonb_build_object(
      'cash_total', v_cash_total,
      'stake_total', v_stake_total,
      'payout_amount', v_cash_total,
      'payout_currency', v_payout_currency,
      'winner_known', false
    );
  elsif v_pool.policy_key = 'proportional' then
    -- FE.8: reparto proporcional — los shares ya vienen en 'contributors'.
    v_result := v_result || jsonb_build_object(
      'distribution', 'proportional_to_basis'
    );
  else  -- equity_target
    if v_pool.target_amount is not null and v_total < v_pool.target_amount then
      v_warnings := v_warnings || to_jsonb('total basis is below target_amount'::text);
      v_result := jsonb_set(v_result, '{warnings}', v_warnings);
    end if;
    v_result := v_result || jsonb_build_object(
      'target_amount', v_pool.target_amount,
      'target_reached', v_total >= coalesce(v_pool.target_amount, 0),
      'target_progress', case when coalesce(v_pool.target_amount, 0) > 0
                              then round(v_total / v_pool.target_amount, 6) else null end,
      'remaining_to_target', greatest(coalesce(v_pool.target_amount, 0) - v_total, 0)
    );
  end if;

  return v_result;
end; $$;

create or replace function public.resolve_pool(
  p_pool_account_id uuid,
  p_resolution jsonb default null,
  p_client_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_pool record;
  v_pol jsonb;
  v_catalog_default boolean;
  v_catalog_meta jsonb;
  v_requires_decision boolean;
  v_ga uuid;
  v_via_governance boolean := false;
  v_entry record;
  v_entry_count int;
  v_cash_total numeric;
  v_stake_total numeric;
  v_total numeric;
  v_money_currency_count int;
  v_payout_currency text;
  v_winner uuid;
  v_payout_txn uuid;
  v_emitted_obligations jsonb := '[]'::jsonb;
  v_emitted_obligation_ids uuid[] := '{}'::uuid[];
  v_settled_count int := 0;
  v_shares jsonb;
  v_result jsonb;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  -- Lock de la fila del pool: resolución concurrente serializa aquí
  select pa.* into v_pool
    from public.pool_accounts pa
   where pa.id = p_pool_account_id
   for update;
  if v_pool.id is null then
    raise exception 'pool_account not found: %', p_pool_account_id using errcode = '42704';
  end if;

  -- Authority: money.settle (más fuerte que el money.record de create_pool —
  -- resolver saca dinero del pool y cierra obligations de terceros; mismo gate
  -- que generate_settlement_batch). Documentado en header.
  if not public.has_actor_authority(v_pool.parent_context_actor_id, v_caller, 'money.settle') then
    raise exception 'not authorized to resolve pool (requires money.settle in parent context)'
      using errcode = '42501';
  end if;

  -- Idempotencia / already_resolved (espejo de execute_decision.already_executed)
  if v_pool.status = 'resolved' then
    if p_client_id is not null and v_pool.metadata->>'resolution_client_id' = p_client_id then
      return coalesce(v_pool.metadata->'resolution_result',
                      jsonb_build_object('pool_account_id', v_pool.id, 'status', 'resolved'))
             || jsonb_build_object('idempotent_replay', true);
    end if;
    return jsonb_build_object(
      'pool_account_id', v_pool.id,
      'status', 'resolved',
      'already_resolved', true,
      'resolved_at', v_pool.resolved_at
    );
  end if;

  if v_pool.status not in ('open', 'target_reached') then
    raise exception 'pool cannot be resolved from status % (expected open or target_reached)',
      v_pool.status using errcode = '22023';
  end if;

  if v_pool.policy_key not in ('winner_takes_all', 'equity_target', 'proportional') then
    raise exception 'pool policy % resolution is not supported yet (winner_takes_all, equity_target, proportional)',
      v_pool.policy_key using errcode = '0A000';
  end if;

  -- ── Governance PULL gate (patrón r7_x_1 / r7_x_4) ──────────────────────────
  -- 1. ¿Hay governance action aprobada para ESTE pool? → vía governance.
  -- 2. Si no: policy explícita del contexto ('pool_resolve_requires_vote')
  --    true → requiere · false → no requiere · ausente → default per-policy del
  --    catalog (plan §3.5: equity_target/custom_spec sí, winner_takes_all no).
  v_ga := public._governance_action_approved(v_pool.parent_context_actor_id, 'pool.resolve', v_pool.id);
  v_via_governance := (v_ga is not null);

  if not v_via_governance then
    v_pol := public.governance_policy(v_pool.parent_context_actor_id, 'pool_resolve_requires_vote');
    select gac.default_requires_decision, gac.metadata
      into v_catalog_default, v_catalog_meta
      from public.governance_action_catalog gac
     where gac.action_key = 'pool.resolve';

    if v_pol = 'true'::jsonb then
      v_requires_decision := true;
    elsif v_pol is not null then
      v_requires_decision := false;  -- override explícito del contexto (ej. false)
    elsif v_catalog_meta is not null and v_catalog_meta ? 'requires_decision_for_policy_keys' then
      v_requires_decision := coalesce(v_catalog_default, false)
        and (v_catalog_meta->'requires_decision_for_policy_keys') ? v_pool.policy_key;
    else
      v_requires_decision := coalesce(v_catalog_default, false);
    end if;

    if v_requires_decision then
      raise exception 'governance_required: pool.resolve requires an approved decision in this context'
        using errcode = '42501',
        hint = 'call request_governance_action(context, ''pool.resolve'', ''pool_account'', pool_account_id) and get it approved first';
    end if;
  end if;

  -- ── Agregados del basis ledger ─────────────────────────────────────────────
  select count(*),
         coalesce(sum(pbe.basis_amount), 0),
         coalesce(sum(pbe.basis_amount) filter (where pbe.basis_kind = 'cash'), 0),
         coalesce(sum(pbe.basis_amount) filter (where pbe.basis_kind = 'pending_stake'), 0),
         count(distinct pbe.currency) filter (where pbe.basis_kind in ('cash', 'pending_stake')),
         min(pbe.currency) filter (where pbe.basis_kind in ('cash', 'pending_stake'))
    into v_entry_count, v_total, v_cash_total, v_stake_total,
         v_money_currency_count, v_payout_currency
    from public.pool_basis_entries pbe
   where pbe.pool_account_id = v_pool.id;

  if v_entry_count = 0 then
    raise exception 'no basis entries to resolve' using errcode = '22023';
  end if;
  if coalesce(v_money_currency_count, 0) > 1 then
    raise exception 'mixed currencies across cash/pending_stake entries are not supported in MVP resolution'
      using errcode = '22023';
  end if;
  v_payout_currency := coalesce(v_pool.currency, v_payout_currency);

  -- ══ Branch winner_takes_all ════════════════════════════════════════════════
  if v_pool.policy_key = 'winner_takes_all' then
    v_winner := nullif(p_resolution->>'winner_actor_id', '')::uuid;
    if v_winner is null then
      raise exception 'winner_takes_all resolution requires p_resolution.winner_actor_id'
        using errcode = '22023';
    end if;
    -- Winner válido: contribuyente del pool o miembro activo del contexto padre
    if not exists (
         select 1 from public.pool_basis_entries pbe
          where pbe.pool_account_id = v_pool.id and pbe.contributor_actor_id = v_winner
       )
       and not exists (
         select 1 from public.actor_memberships am
          where am.context_actor_id = v_pool.parent_context_actor_id
            and am.member_actor_id = v_winner
            and am.membership_status = 'active'
       )
    then
      raise exception 'winner_actor_id must be a pool contributor or an active member of the parent context'
        using errcode = '22023';
    end if;

    -- 1. Payout del cash genuino: pool actor → winner (type='payout', ya en CHECK).
    --    Solo si hubo cash real; un bote puro de pending_stake no mueve transaction.
    if v_cash_total > 0 then
      insert into public.money_transactions
        (context_actor_id, from_actor_id, to_actor_id, transaction_type,
         amount, currency, metadata, created_by_actor_id)
      values
        (v_pool.parent_context_actor_id, v_pool.pool_actor_id, v_winner, 'payout',
         v_cash_total, v_payout_currency,
         jsonb_build_object(
           'pool_account_id', v_pool.id,
           'pool_resolution', 'winner_takes_all',
           'winner_actor_id', v_winner
         ),
         v_caller)
      returning id into v_payout_txn;

      -- Splits espejo de record_expense: el pool actor es el payer, el winner
      -- el beneficiary (monto completo en ambos lados).
      insert into public.money_splits (transaction_id, actor_id, split_role, amount, currency)
      values
        (v_payout_txn, v_pool.pool_actor_id, 'payer', v_cash_total, v_payout_currency),
        (v_payout_txn, v_winner, 'beneficiary', v_cash_total, v_payout_currency);

      perform public._emit_activity(
        v_pool.parent_context_actor_id, v_caller, 'pool.payout',
        'pool_account', v_pool.id,
        jsonb_build_object(
          'pool_account_id', v_pool.id,
          'winner_actor_id', v_winner,
          'payout_transaction_id', v_payout_txn,
          'amount', v_cash_total,
          'currency', v_payout_currency
        )
      );
    end if;

    -- 2. Transiciones de obligations pending_pool pareadas (via paired_obligation_id):
    --    · cash → settled (el dinero ya entró al pool; el payout lo saca — ciclo cerrado)
    --    · pending_stake del propio winner → settled (auto-neteo, nadie se debe a sí mismo)
    --    · pending_stake de terceros → CRISTALIZA per plan §1.4: creditor=winner,
    --      status='open' → entra al settlement normal (R.2N sin cambios)
    for v_entry in
      select pbe.id as basis_entry_id, pbe.basis_kind, pbe.paired_obligation_id,
             o.debtor_actor_id, o.amount, o.currency
        from public.pool_basis_entries pbe
        join public.obligations o on o.id = pbe.paired_obligation_id
       where pbe.pool_account_id = v_pool.id
         and o.status = 'pending_pool'
    loop
      if v_entry.basis_kind = 'cash' or v_entry.debtor_actor_id = v_winner then
        update public.obligations
           set status = 'settled',
               metadata = metadata || jsonb_build_object(
                 'settled_reason', case when v_entry.basis_kind = 'cash'
                                        then 'pool_resolved_cash_contribution'
                                        else 'pool_resolved_winner_self_stake' end,
                 'pool_account_id', v_pool.id,
                 'pool_resolution', 'winner_takes_all',
                 'pool_resolved_at', now())
         where id = v_entry.paired_obligation_id;
        v_settled_count := v_settled_count + 1;

        update public.pool_basis_entries
           set resolved_at = now()
         where id = v_entry.basis_entry_id;
      else
        update public.obligations
           set status = 'open',
               creditor_actor_id = v_winner,
               metadata = metadata || jsonb_build_object(
                 'crystallized_from', 'pending_pool',
                 'previous_creditor_actor_id', v_pool.pool_actor_id,
                 'pool_account_id', v_pool.id,
                 'pool_resolution', 'winner_takes_all',
                 'pool_resolved_at', now())
         where id = v_entry.paired_obligation_id;

        update public.pool_basis_entries
           set resolved_at = now(),
               resolution_obligation_ids = array[v_entry.paired_obligation_id]
         where id = v_entry.basis_entry_id;

        v_emitted_obligation_ids := v_emitted_obligation_ids || v_entry.paired_obligation_id;
        v_emitted_obligations := v_emitted_obligations || jsonb_build_object(
          'obligation_id', v_entry.paired_obligation_id,
          'debtor', v_entry.debtor_actor_id,
          'creditor', v_winner,
          'amount', v_entry.amount,
          'currency', v_entry.currency
        );
      end if;
    end loop;

    -- 3. Entries sin obligation pareada (asset/service): solo stamp. La
    --    transferencia física del asset queda fuera de scope MVP (plan §9).
    update public.pool_basis_entries
       set resolved_at = now()
     where pool_account_id = v_pool.id and resolved_at is null;

    v_result := jsonb_build_object(
      'pool_account_id', v_pool.id,
      'status', 'resolved',
      'policy_key', 'winner_takes_all',
      'winner_actor_id', v_winner,
      'payout_transaction_id', v_payout_txn,
      'payout_amount', v_cash_total,
      'payout_currency', v_payout_currency,
      'emitted_obligations', v_emitted_obligations,
      'settled_obligation_count', v_settled_count
    );

  -- ══ Branch equity_target (mínimo viable firmado) ═══════════════════════════
  elsif v_pool.policy_key in ('equity_target', 'proportional') then
    -- FE.8: equity_target y proportional comparten materialización (shares
    -- proporcionales + settle de aportes, sin payout — la conversión a
    -- rights/nivelación queda DEFERRED a R.9). Difieren solo en semántica
    -- (meta vs reparto directo) y en el shape del result.
    -- Shares proporcionales por contribuyente: basis / total. Se persisten en
    -- metadata.resolution_shares — la conversión a resource rights compartidos
    -- y las obligations de nivelación B→A quedan DEFERRED a R.9 (plan §9:
    -- "MVP: resolve_pool emite obligations + manualmente se crea el resource +
    -- grants"). Aquí la versión mínima: resolved + shares + settle pending_pool.
    select coalesce(jsonb_agg(jsonb_build_object(
      'actor_id', c.contributor_actor_id,
      'basis_amount', c.basis,
      'share', case when v_total > 0 then round(c.basis / v_total, 6) else 0 end
    ) order by c.basis desc, c.contributor_actor_id), '[]'::jsonb)
      into v_shares
      from (
        select pbe.contributor_actor_id, sum(pbe.basis_amount) as basis
          from public.pool_basis_entries pbe
         where pbe.pool_account_id = v_pool.id
         group by pbe.contributor_actor_id
      ) c;

    -- Settle de las obligations pending_pool pareadas: el cash aportado queda
    -- como capital conjunto del pool resuelto (no hay payout en equity_target).
    update public.obligations o
       set status = 'settled',
           metadata = o.metadata || jsonb_build_object(
             'settled_reason', 'pool_resolved_' || v_pool.policy_key,
             'pool_account_id', v_pool.id,
             'pool_resolution', v_pool.policy_key,
             'pool_resolved_at', now())
      from public.pool_basis_entries pbe
     where pbe.pool_account_id = v_pool.id
       and pbe.paired_obligation_id = o.id
       and o.status = 'pending_pool';
    get diagnostics v_settled_count = row_count;

    update public.pool_basis_entries
       set resolved_at = now()
     where pool_account_id = v_pool.id and resolved_at is null;

    v_result := jsonb_build_object(
      'pool_account_id', v_pool.id,
      'status', 'resolved',
      'policy_key', v_pool.policy_key,
      'total_basis', v_total,
      'shares', v_shares,
      'settled_obligation_count', v_settled_count,
      'emitted_obligations', '[]'::jsonb
    );
    if v_pool.policy_key = 'equity_target' then
      v_result := v_result || jsonb_build_object(
        'target_amount', v_pool.target_amount,
        'target_reached', v_total >= coalesce(v_pool.target_amount, 0)
      );
    end if;
  end if;

  -- ── Finalización común ─────────────────────────────────────────────────────
  update public.pool_accounts
     set status = 'resolved',
         resolved_at = now(),
         resolved_payload = coalesce(p_resolution, '{}'::jsonb),
         metadata = metadata || jsonb_strip_nulls(jsonb_build_object(
           'resolution_client_id', p_client_id,
           'resolution_result', v_result,
           'resolution_shares', v_shares,
           'resolved_by_actor_id', v_caller,
           'via_governance', v_via_governance,
           'governance_action_id', v_ga
         ))
   where id = v_pool.id;

  -- Marcar governance action ejecutada si vinimos vía PULL approval
  if v_ga is not null then
    update public.governance_actions
       set status = 'executed', executed_by_actor_id = v_caller, executed_at = now()
     where id = v_ga;
  end if;

  perform public._emit_activity(
    v_pool.parent_context_actor_id, v_caller, 'pool.resolved',
    'pool_account', v_pool.id,
    jsonb_strip_nulls(jsonb_build_object(
      'pool_account_id', v_pool.id,
      'policy_key', v_pool.policy_key,
      'resolution', coalesce(p_resolution, '{}'::jsonb),
      'emitted_obligation_ids', to_jsonb(v_emitted_obligation_ids),
      'payout_transaction_id', v_payout_txn,
      'settled_obligation_count', v_settled_count,
      'via_governance', v_via_governance,
      'governance_action_id', v_ga
    ))
  );

  return v_result;
end; $$;

-- Smoke
create or replace function public._smoke_mvp2_pool_proportional()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_a uuid;
  v_ctx uuid;
  v_pool uuid;
  v_pool_actor uuid;
  v_result jsonb;
begin
  v_a := public._create_person_actor_for_auth_user(v_auth_a, 'Smoke Prop A', '+520000000950', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth_a::text)::text, true);
  v_result := public.create_context('_smoke_prop Viaje', 'collective', 'trip');
  v_ctx := (v_result->>'context_actor_id')::uuid;

  v_result := public.create_pool(v_ctx, '_smoke_prop Fondo', 'proportional',
    p_currency := 'MXN');
  v_pool := (v_result->>'pool_account_id')::uuid;
  select pool_actor_id into v_pool_actor from public.pool_accounts where id = v_pool;

  perform public.contribute_to_pool(v_pool, 'cash', 300, 'MXN');

  -- Preview expone distribution proporcional.
  v_result := public.preview_pool_resolution(v_pool);
  if (v_result->>'distribution') <> 'proportional_to_basis' then
    raise exception 'prop smoke: preview sin distribution proporcional (got %)', v_result->>'distribution';
  end if;

  -- Resolve directo (proportional no exige voto por default en el catálogo).
  v_result := public.resolve_pool(v_pool, '{}'::jsonb, null);
  if (v_result->>'policy_key') <> 'proportional' or (v_result->>'status') <> 'resolved' then
    raise exception 'prop smoke: resolve falló (%)', v_result::text;
  end if;
  if jsonb_array_length(v_result->'shares') < 1 then
    raise exception 'prop smoke: sin shares en el resultado';
  end if;
  if not exists (select 1 from public.pool_accounts where id = v_pool and status = 'resolved') then
    raise exception 'prop smoke: pool no quedó resolved';
  end if;

  -- Cleanup (activity append-only — residuo aceptado).
  perform set_config('request.jwt.claims', null, true);
  -- pool_basis_entries referencia money_transactions: borrar entries primero.
  delete from public.pool_basis_entries where pool_account_id = v_pool;
  delete from public.money_splits ms using public.money_transactions mt
    where mt.id = ms.transaction_id and mt.context_actor_id = v_ctx;
  delete from public.money_transactions where context_actor_id = v_ctx;
  delete from public.obligations where context_actor_id = v_ctx;
  delete from public.pool_accounts where id = v_pool;
  delete from public.context_invites where context_actor_id = v_ctx;
  delete from public.role_assignments where context_actor_id = v_ctx;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_ctx;
  delete from public.roles where context_actor_id = v_ctx;
  delete from public.actor_memberships where context_actor_id = v_ctx;
  delete from public.actor_relationships
    where subject_actor_id in (v_a, v_ctx, v_pool_actor)
       or object_actor_id in (v_a, v_ctx, v_pool_actor);
  -- El pool actor fue creado por A (actors.created_by_actor_id): borrarlo
  -- ANTES que la persona — el id se capturó antes de borrar pool_accounts.
  delete from public.actors where id = v_pool_actor;
  delete from public.actors where id = v_ctx;
  delete from public.person_profiles where actor_id = v_a;
  delete from public.actors where id = v_a;
  delete from auth.users where id = v_auth_a;

  raise notice '_smoke_mvp2_pool_proportional passed';
end; $$;

revoke all on function public._smoke_mvp2_pool_proportional() from public, anon, authenticated;
