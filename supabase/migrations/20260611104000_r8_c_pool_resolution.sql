-- ============================================================================
-- R.8.C — POOL PRIMITIVE · RESOLUCIÓN
-- ============================================================================
-- Cierra el ciclo del Pool (R.8): el dinero ya podía ENTRAR (create_pool +
-- contribute_to_pool, R.8.B) pero no podía SALIR. Este migration agrega la
-- resolución para las DOS políticas MVP:
--
--   · winner_takes_all  → el pot de cash sale del pool actor al ganador vía
--     money_transaction type='payout' (CHECK ya lo permite desde mvp2_009).
--     Las obligations pending_pool de cash se settlean (el dinero ya se movió
--     físicamente en la contribución; el payout cierra el ciclo). Los
--     pending_stake se CRISTALIZAN per doctrina §1.4: UPDATE creditor_actor_id
--     = winner + status='open' → entran al settlement normal (R.2N intacto).
--   · equity_target     → versión mínima viable firmada en el plan: calcula el
--     share proporcional de cada contribuyente (basis / total), lo persiste en
--     pool_accounts.metadata.resolution_shares, settlea las obligations
--     pending_pool pareadas y marca el pool resolved.
--
-- RPCs nuevos:
--   · preview_pool_resolution(p_pool_account_id)            — read-only, sin mutar
--   · resolve_pool(p_pool_account_id, p_resolution, p_client_id) — SECURITY DEFINER
--
-- Integración doctrinal:
--   · Permission: money.settle (MÁS FUERTE que el money.record de create_pool —
--     resolver mueve dinero fuera del pool y cierra obligations de terceros,
--     mismo nivel que generate_settlement_batch / forgive_obligation admin path).
--   · Governance R.7 (PULL, mismo patrón que r7_x_1/r7_x_4): catalog row nuevo
--     'pool.resolve' con default_requires_decision=true + per-policy nuance del
--     plan §3.5 vía metadata.requires_decision_for_policy_keys =
--     ['equity_target','custom_spec'] (winner_takes_all NO requiere voto por
--     default; el contexto puede overridear con governance_policy
--     'pool_resolve_requires_vote' true/false). push_supported=false: resolve_pool
--     consume _governance_action_approved (PULL) y marca la action executed él
--     mismo — PUSH duplicaría (misma razón que member.remove).
--   · Idempotencia: p_client_id se persiste en pool_accounts.metadata
--     (resolution_client_id + resolution_result). Replay con el mismo client_id
--     devuelve el resultado original con idempotent_replay=true. Re-resolve de
--     un pool ya resuelto (sin client_id match) devuelve already_resolved=true
--     (espejo de execute_decision → already_executed).
--   · Activity: pool.resolved + pool.payout entran al activity_event_catalog
--     (mismo estilo que pool.created/pool.contributed en R.8.B).
--   · Errcodes: 28000 unauthenticated · 42501 not authorized / governance_required
--     · 22023 validation · 42704 not found · 0A000 política no soportada en MVP.
--
-- Deferred (explícito, NO inventado más allá del plan):
--   · Políticas proportional / equal_share / rotational / custom_spec → 0A000.
--   · pool.target_reached trigger automático (equity_target) → slice posterior.
--   · equity_target NO genera resource rights compartidos ni obligations de
--     nivelación B→A (plan §9: "MVP: resolve_pool emite obligations + manualmente
--     se crea el resource + grants. R.9 candidate"). Aquí: shares en metadata.
--   · Refund de cash al cancelar → fuera de scope (plan §9).
--
-- Plan canónico: Plans/Active/R8_PoolPrimitive.md (§1.4 resolución · §3.2 RPCs ·
-- §3.5 governance · §8 R.8.C DoD · §9 out-of-scope).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Activity catalog: pool.resolved + pool.payout
-- ────────────────────────────────────────────────────────────────────────────
insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, is_system_generated)
values
  ('pool.resolved', 'pool', 'El fondo se resolvió según su política (basis ledger → obligations pairwise / payout)',
   'pool_account', false),
  ('pool.payout',   'pool', 'El fondo pagó el pot de cash a un actor (winner_takes_all)',
   'pool_account', false)
on conflict (event_type) do nothing;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Governance catalog: pool.resolve (PULL wire, patrón r7_a/r7_x_4)
-- ────────────────────────────────────────────────────────────────────────────
-- default_requires_decision=true a nivel catalog (acción dangerous: mueve dinero
-- y cierra obligations), PERO el plan §3.5 firma nuance per-policy:
-- requires_decision para equity_target/custom_spec, not_required para
-- winner_takes_all. resolve_pool lee metadata.requires_decision_for_policy_keys
-- cuando NO hay governance_policy explícita en el contexto.
insert into public.governance_action_catalog (
  action_key, display_name, domain, default_requires_decision,
  policy_key, execution_rpc, push_supported, dangerous,
  legacy_aliases, metadata
) values
  ('pool.resolve',
   'Resolver fondo',
   'money',
   true,
   'pool_resolve_requires_vote',
   'resolve_pool',
   false,
   true,
   array[]::text[],
   jsonb_build_object(
     'description', 'Resuelve un fondo de capital colectivo: el basis ledger se transforma en payout + obligations pairwise según la política.',
     'requires_decision_for_policy_keys', jsonb_build_array('equity_target', 'custom_spec'),
     'r8c_notes', 'R.8.C shipped. PULL-only: resolve_pool consume _governance_action_approved y marca la action executed — push_supported=false para no duplicar (misma razón que member.remove). Per-policy default del plan §3.5 vía requires_decision_for_policy_keys; governance_policy pool_resolve_requires_vote (true/false) lo overridea per-contexto.'
   ))
on conflict (action_key) do update set
  display_name = excluded.display_name,
  domain = excluded.domain,
  default_requires_decision = excluded.default_requires_decision,
  policy_key = excluded.policy_key,
  execution_rpc = excluded.execution_rpc,
  push_supported = excluded.push_supported,
  dangerous = excluded.dangerous,
  legacy_aliases = excluded.legacy_aliases,
  metadata = excluded.metadata,
  updated_at = now();

-- ────────────────────────────────────────────────────────────────────────────
-- 3. preview_pool_resolution
-- ────────────────────────────────────────────────────────────────────────────
-- Read-only: calcula la resolución SIN mutar nada. Gate de lectura espejo de
-- pool_account_detail (miembro del contexto padre o contribuyente directo).
--
--   · winner_takes_all → composición del pot: total cash, stakes pendientes,
--     contribuyentes con basis + share. El winner NO se conoce en preview
--     (se pasa en resolve) → winner_known=false.
--   · equity_target    → share de cada contribuyente (basis / total) + progreso
--     contra target_amount.
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

  if v_pool.policy_key not in ('winner_takes_all', 'equity_target') then
    raise exception 'pool policy % resolution is not supported yet (MVP: winner_takes_all, equity_target)',
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

revoke all on function public.preview_pool_resolution(uuid) from public, anon;
grant execute on function public.preview_pool_resolution(uuid) to authenticated, service_role;

comment on function public.preview_pool_resolution(uuid) is
  'R.8.C: preview read-only de la resolución del pool. winner_takes_all → composición del pot (winner desconocido); equity_target → shares proporcionales + progreso a target. No muta.';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. resolve_pool
-- ────────────────────────────────────────────────────────────────────────────
-- SECURITY DEFINER. Lock FOR UPDATE sobre pool_accounts (resolución es
-- all-or-nothing en una transacción — el status intermedio ''resolving'' del
-- CHECK queda reservado para flows async post-MVP).
--
-- p_resolution por política (plan §3.2):
--   · winner_takes_all → {winner_actor_id: uuid}  (requerido)
--   · equity_target    → {} | null | {force_close: bool} (informativo, se audita)
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

  if v_pool.policy_key not in ('winner_takes_all', 'equity_target') then
    raise exception 'pool policy % resolution is not supported yet (MVP: winner_takes_all, equity_target)',
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
  else
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
             'settled_reason', 'pool_resolved_equity_target',
             'pool_account_id', v_pool.id,
             'pool_resolution', 'equity_target',
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
      'policy_key', 'equity_target',
      'total_basis', v_total,
      'target_amount', v_pool.target_amount,
      'target_reached', v_total >= coalesce(v_pool.target_amount, 0),
      'shares', v_shares,
      'settled_obligation_count', v_settled_count,
      'emitted_obligations', '[]'::jsonb
    );
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

revoke all on function public.resolve_pool(uuid, jsonb, text) from public, anon;
grant execute on function public.resolve_pool(uuid, jsonb, text) to authenticated, service_role;

comment on function public.resolve_pool(uuid, jsonb, text) is
  'R.8.C: resuelve el pool según su política. winner_takes_all → payout pool→winner + crystallize stakes a obligations open; equity_target → shares en metadata + settle pending_pool (mínimo viable, rights/nivelación deferred R.9). Permission: money.settle. Governance PULL: pool_resolve_requires_vote / catalog per-policy default. Idempotente por p_client_id; already_resolved si ya se resolvió.';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Smokes R.8.C
-- ────────────────────────────────────────────────────────────────────────────
-- Estructura espejo de R.8.B: funciones individuales _smoke_r8_c_* + UN wrapper
-- _smoke_mvp2_r8_c_pool_resolution() (CI solo corre _smoke_mvp2_%).
-- Cleanup: los pools NO están cubiertos por _r2_cleanup_context, así que cada
-- smoke borra pool_accounts (cascade a basis entries) + transactions/obligations
-- + el pool actor ANTES de llamar el cleanup genérico (el pool actor referencia
-- created_by_actor_id y es referenciado por el payout transaction).

-- 5.1 winner_takes_all happy path + idempotency + already_resolved
create or replace function public._smoke_r8_c_winner_takes_all_happy_path()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  u_b uuid := gen_random_uuid();
  u_c uuid := gen_random_uuid();
  u_d uuid := gen_random_uuid();
  a_a uuid; a_b uuid; a_c uuid; a_d uuid;
  v_ctx uuid; v_code text;
  v_pool jsonb; v_pool_account uuid; v_pool_actor uuid;
  v_preview jsonb;
  v_result jsonb; v_replay jsonb;
  v_payout_txn uuid;
  v_count int;
  v_share_sum numeric;
  v_ob record;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R8C Host', '+520000000830', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R8C Winner', '+520000000831', null);
  a_c := public._create_person_actor_for_auth_user(u_c, 'R8C Player', '+520000000832', null);
  a_d := public._create_person_actor_for_auth_user(u_d, 'R8C Staker', '+520000000833', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r8c Bote', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.join_by_invite_code(v_code);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_d::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Pool winner_takes_all + 3 aportes cash (100/200/300) + 1 pending_stake (150)
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_pool := public.create_pool(v_ctx, 'Bote Happy King', 'winner_takes_all', p_currency := 'MXN');
  v_pool_account := (v_pool->>'pool_account_id')::uuid;
  v_pool_actor := (v_pool->>'pool_actor_id')::uuid;

  perform public.contribute_to_pool(v_pool_account, 'cash', 100, 'MXN');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.contribute_to_pool(v_pool_account, 'cash', 200, 'MXN');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text)::text, true);
  perform public.contribute_to_pool(v_pool_account, 'cash', 300, 'MXN');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_d::text)::text, true);
  perform public.contribute_to_pool(v_pool_account, 'pending_stake', 150, 'MXN');

  -- ── preview: composición del pot ──
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_preview := public.preview_pool_resolution(v_pool_account);
  if (v_preview->>'resolution_kind') <> 'winner_takes_all' then
    raise exception 'r8_c preview: resolution_kind incorrecto (%)', v_preview->>'resolution_kind';
  end if;
  if (v_preview->>'total_basis')::numeric <> 750 then
    raise exception 'r8_c preview: total_basis esperaba 750, got %', v_preview->>'total_basis';
  end if;
  if (v_preview->>'cash_total')::numeric <> 600 then
    raise exception 'r8_c preview: cash_total esperaba 600, got %', v_preview->>'cash_total';
  end if;
  if (v_preview->>'stake_total')::numeric <> 150 then
    raise exception 'r8_c preview: stake_total esperaba 150, got %', v_preview->>'stake_total';
  end if;
  if (v_preview->>'payout_amount')::numeric <> 600 then
    raise exception 'r8_c preview: payout_amount esperaba 600 (solo cash), got %', v_preview->>'payout_amount';
  end if;
  if jsonb_array_length(v_preview->'contributors') <> 4 then
    raise exception 'r8_c preview: esperaba 4 contributors';
  end if;
  if (v_preview->>'winner_known')::bool is not false then
    raise exception 'r8_c preview: winner_known debió ser false';
  end if;
  select sum((c->>'share')::numeric) into v_share_sum
    from jsonb_array_elements(v_preview->'contributors') c;
  if abs(v_share_sum - 1) > 0.000005 then
    raise exception 'r8_c preview: shares no suman 1 (%)', v_share_sum;
  end if;

  -- ── resolve con winner = a_b ──
  v_result := public.resolve_pool(
    v_pool_account,
    jsonb_build_object('winner_actor_id', a_b),
    p_client_id := 'r8c-resolve-1'
  );
  if (v_result->>'status') <> 'resolved' then
    raise exception 'r8_c resolve: status esperaba resolved, got %', v_result->>'status';
  end if;
  v_payout_txn := (v_result->>'payout_transaction_id')::uuid;
  if v_payout_txn is null then
    raise exception 'r8_c resolve: falta payout_transaction_id';
  end if;
  if (v_result->>'payout_amount')::numeric <> 600 then
    raise exception 'r8_c resolve: payout_amount esperaba 600, got %', v_result->>'payout_amount';
  end if;

  -- payout transaction: pool actor → winner, type=payout, monto correcto
  if not exists (
    select 1 from public.money_transactions
     where id = v_payout_txn and context_actor_id = v_ctx
       and from_actor_id = v_pool_actor and to_actor_id = a_b
       and transaction_type = 'payout' and amount = 600 and currency = 'MXN'
  ) then
    raise exception 'r8_c resolve: payout transaction pool→winner incorrecta';
  end if;
  -- splits: payer (pool actor) + beneficiary (winner)
  if not exists (select 1 from public.money_splits
                  where transaction_id = v_payout_txn and actor_id = v_pool_actor
                    and split_role = 'payer' and amount = 600) then
    raise exception 'r8_c resolve: falta split payer del pool actor';
  end if;
  if not exists (select 1 from public.money_splits
                  where transaction_id = v_payout_txn and actor_id = a_b
                    and split_role = 'beneficiary' and amount = 600) then
    raise exception 'r8_c resolve: falta split beneficiary del winner';
  end if;

  -- obligations: 0 pending_pool restantes; las 3 cash → settled
  select count(*) into v_count from public.obligations
   where context_actor_id = v_ctx and status = 'pending_pool';
  if v_count <> 0 then
    raise exception 'r8_c resolve: quedaron % obligations pending_pool', v_count;
  end if;
  select count(*) into v_count from public.obligations
   where context_actor_id = v_ctx and status = 'settled'
     and metadata->>'pool_account_id' = v_pool_account::text
     and metadata->>'settled_reason' = 'pool_resolved_cash_contribution';
  if v_count <> 3 then
    raise exception 'r8_c resolve: esperaba 3 obligations cash settled, got %', v_count;
  end if;

  -- el pending_stake de a_d cristalizó: creditor = winner, status = open (plan §1.4)
  select o.* into v_ob from public.obligations o
   where o.context_actor_id = v_ctx and o.debtor_actor_id = a_d
     and o.metadata->>'crystallized_from' = 'pending_pool';
  if v_ob.id is null then
    raise exception 'r8_c resolve: stake de a_d no cristalizó';
  end if;
  if v_ob.status <> 'open' or v_ob.creditor_actor_id <> a_b or v_ob.amount <> 150 then
    raise exception 'r8_c resolve: stake cristalizado mal (status=% creditor=% amount=%)',
      v_ob.status, v_ob.creditor_actor_id, v_ob.amount;
  end if;
  if jsonb_array_length(v_result->'emitted_obligations') <> 1 then
    raise exception 'r8_c resolve: esperaba 1 emitted_obligation (el stake)';
  end if;

  -- pool resuelto + basis entries stamped
  if (select status from public.pool_accounts where id = v_pool_account) <> 'resolved' then
    raise exception 'r8_c resolve: pool no quedó resolved';
  end if;
  if (select resolved_at from public.pool_accounts where id = v_pool_account) is null then
    raise exception 'r8_c resolve: resolved_at null';
  end if;
  if exists (select 1 from public.pool_basis_entries
              where pool_account_id = v_pool_account and resolved_at is null) then
    raise exception 'r8_c resolve: quedaron basis entries sin resolved_at';
  end if;

  -- activity: pool.resolved + pool.payout emitidos
  if (select count(*) from public.activity_events
       where context_actor_id = v_ctx and event_type = 'pool.resolved'
         and subject_id = v_pool_account) <> 1 then
    raise exception 'r8_c resolve: activity pool.resolved no emitida';
  end if;
  if (select count(*) from public.activity_events
       where context_actor_id = v_ctx and event_type = 'pool.payout'
         and subject_id = v_pool_account) <> 1 then
    raise exception 'r8_c resolve: activity pool.payout no emitida';
  end if;

  -- ── idempotency: mismo client_id → replay sin duplicados ──
  v_replay := public.resolve_pool(
    v_pool_account,
    jsonb_build_object('winner_actor_id', a_b),
    p_client_id := 'r8c-resolve-1'
  );
  if (v_replay->>'idempotent_replay')::bool is not true then
    raise exception 'r8_c idempotency: replay no marcó idempotent_replay';
  end if;
  if (v_replay->>'payout_transaction_id')::uuid <> v_payout_txn then
    raise exception 'r8_c idempotency: replay devolvió otro payout txn';
  end if;
  select count(*) into v_count from public.money_transactions
   where context_actor_id = v_ctx and transaction_type = 'payout';
  if v_count <> 1 then
    raise exception 'r8_c idempotency: replay duplicó payout (% txns)', v_count;
  end if;

  -- ── already_resolved: re-resolve sin client_id match ──
  v_replay := public.resolve_pool(v_pool_account, jsonb_build_object('winner_actor_id', a_c));
  if (v_replay->>'already_resolved')::bool is not true then
    raise exception 'r8_c already_resolved: esperaba already_resolved=true';
  end if;

  -- Cleanup (pools no cubiertos por _r2_cleanup_context — orden por FKs)
  perform set_config('request.jwt.claims', null, true);
  delete from public.pool_accounts where parent_context_actor_id = v_ctx;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = v_ctx);
  delete from public.money_transactions where context_actor_id = v_ctx;
  delete from public.obligations where context_actor_id = v_ctx;
  delete from public.actors where id = v_pool_actor;
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b, a_c, a_d], array[u_a, u_b, u_c, u_d]);
  raise notice '_smoke_r8_c_winner_takes_all_happy_path passed';
end; $$;
revoke all on function public._smoke_r8_c_winner_takes_all_happy_path() from public, anon, authenticated;

-- 5.2 permission denial: miembro sin money.settle + unauthenticated
create or replace function public._smoke_r8_c_resolve_permission_denial()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid;
  v_ctx uuid; v_code text;
  v_pool jsonb; v_pool_account uuid; v_pool_actor uuid;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R8C Admin', '+520000000834', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R8C Member', '+520000000835', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r8c Perm', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_pool := public.create_pool(v_ctx, 'Bote Perm', 'winner_takes_all', p_currency := 'MXN');
  v_pool_account := (v_pool->>'pool_account_id')::uuid;
  v_pool_actor := (v_pool->>'pool_actor_id')::uuid;
  perform public.contribute_to_pool(v_pool_account, 'cash', 100, 'MXN');

  -- miembro normal (sin money.settle) SÍ puede preview (read-only de miembro)…
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.preview_pool_resolution(v_pool_account);
  -- …pero NO puede resolver
  begin
    perform public.resolve_pool(v_pool_account, jsonb_build_object('winner_actor_id', a_b));
    raise exception 'r8_c perm: miembro sin money.settle resolvió el pool';
  exception when sqlstate '42501' then null;
  end;

  -- unauthenticated
  perform set_config('request.jwt.claims', null, true);
  begin
    perform public.resolve_pool(v_pool_account, jsonb_build_object('winner_actor_id', a_b));
    raise exception 'r8_c perm: unauthenticated debió fallar';
  exception when sqlstate '28000' then null;
  end;

  -- el pool sigue intacto (open, sin payout)
  if (select status from public.pool_accounts where id = v_pool_account) <> 'open' then
    raise exception 'r8_c perm: pool cambió de status tras denials';
  end if;
  if exists (select 1 from public.money_transactions
              where context_actor_id = v_ctx and transaction_type = 'payout') then
    raise exception 'r8_c perm: se creó payout pese a denial';
  end if;

  delete from public.pool_accounts where parent_context_actor_id = v_ctx;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = v_ctx);
  delete from public.money_transactions where context_actor_id = v_ctx;
  delete from public.obligations where context_actor_id = v_ctx;
  delete from public.actors where id = v_pool_actor;
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r8_c_resolve_permission_denial passed';
end; $$;
revoke all on function public._smoke_r8_c_resolve_permission_denial() from public, anon, authenticated;

-- 5.3 equity_target: preview shares + default governance per-policy + resolución
create or replace function public._smoke_r8_c_equity_target_resolution()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid;
  v_ctx uuid; v_code text;
  v_pool jsonb; v_pool_account uuid; v_pool_actor uuid;
  v_preview jsonb;
  v_result jsonb;
  v_shares jsonb;
  v_share_sum numeric;
  v_count int;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R8C Socio A', '+520000000836', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R8C Socio B', '+520000000837', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r8c JV', 'collective', 'family'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_pool := public.create_pool(v_ctx, 'JV Nave', 'equity_target',
    p_currency := 'MXN', p_target_amount := 1000);
  v_pool_account := (v_pool->>'pool_account_id')::uuid;
  v_pool_actor := (v_pool->>'pool_actor_id')::uuid;

  perform public.contribute_to_pool(v_pool_account, 'cash', 250, 'MXN');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.contribute_to_pool(v_pool_account, 'cash', 750, 'MXN');

  -- ── preview: shares 0.25 / 0.75 que suman 1 + target alcanzado ──
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_preview := public.preview_pool_resolution(v_pool_account);
  if (v_preview->>'resolution_kind') <> 'equity_target' then
    raise exception 'r8_c equity preview: resolution_kind incorrecto';
  end if;
  if (v_preview->>'total_basis')::numeric <> 1000 then
    raise exception 'r8_c equity preview: total_basis esperaba 1000';
  end if;
  if (v_preview->>'target_reached')::bool is not true then
    raise exception 'r8_c equity preview: target_reached debió ser true';
  end if;
  if (v_preview->>'target_progress')::numeric <> 1 then
    raise exception 'r8_c equity preview: target_progress esperaba 1';
  end if;
  select sum((c->>'share')::numeric) into v_share_sum
    from jsonb_array_elements(v_preview->'contributors') c;
  if abs(v_share_sum - 1) > 0.000005 then
    raise exception 'r8_c equity preview: shares no suman 1 (%)', v_share_sum;
  end if;
  if not exists (select 1 from jsonb_array_elements(v_preview->'contributors') c
                  where (c->>'actor_id')::uuid = a_b and (c->>'share')::numeric = 0.75) then
    raise exception 'r8_c equity preview: share de socio B debió ser 0.75';
  end if;

  -- ── default per-policy del catalog (plan §3.5): equity_target SIN policy
  --    explícita en el contexto → governance_required ──
  begin
    perform public.resolve_pool(v_pool_account);
    raise exception 'r8_c equity: resolve procedió sin decisión (default requires_decision)';
  exception when sqlstate '42501' then
    if sqlerrm not like 'governance_required%' then
      raise exception 'r8_c equity: mensaje inesperado: %', sqlerrm;
    end if;
  end;

  -- ── override explícito del contexto: pool_resolve_requires_vote=false ──
  perform public.update_governance_policy(v_ctx, 'pool_resolve_requires_vote', 'false'::jsonb);
  v_result := public.resolve_pool(v_pool_account, p_client_id := 'r8c-equity-1');
  if (v_result->>'status') <> 'resolved' then
    raise exception 'r8_c equity: status esperaba resolved';
  end if;
  if (v_result->>'target_reached')::bool is not true then
    raise exception 'r8_c equity: target_reached debió ser true en resolve';
  end if;
  if jsonb_array_length(v_result->'shares') <> 2 then
    raise exception 'r8_c equity: esperaba 2 shares';
  end if;

  -- shares persistidos en metadata del pool
  v_shares := (select metadata->'resolution_shares' from public.pool_accounts where id = v_pool_account);
  if v_shares is null or jsonb_array_length(v_shares) <> 2 then
    raise exception 'r8_c equity: resolution_shares no persistido en metadata';
  end if;
  select sum((s->>'share')::numeric) into v_share_sum from jsonb_array_elements(v_shares) s;
  if abs(v_share_sum - 1) > 0.000005 then
    raise exception 'r8_c equity: resolution_shares no suman 1 (%)', v_share_sum;
  end if;

  -- pending_pool pareadas → settled; pool resolved; activity pool.resolved
  select count(*) into v_count from public.obligations
   where context_actor_id = v_ctx and status = 'pending_pool';
  if v_count <> 0 then
    raise exception 'r8_c equity: quedaron % pending_pool', v_count;
  end if;
  select count(*) into v_count from public.obligations
   where context_actor_id = v_ctx and status = 'settled'
     and metadata->>'settled_reason' = 'pool_resolved_equity_target';
  if v_count <> 2 then
    raise exception 'r8_c equity: esperaba 2 obligations settled, got %', v_count;
  end if;
  if (select status from public.pool_accounts where id = v_pool_account) <> 'resolved' then
    raise exception 'r8_c equity: pool no quedó resolved';
  end if;
  -- equity_target NO emite payout
  if exists (select 1 from public.money_transactions
              where context_actor_id = v_ctx and transaction_type = 'payout') then
    raise exception 'r8_c equity: no debió haber payout';
  end if;
  if (select count(*) from public.activity_events
       where context_actor_id = v_ctx and event_type = 'pool.resolved'
         and subject_id = v_pool_account) <> 1 then
    raise exception 'r8_c equity: activity pool.resolved no emitida';
  end if;

  perform set_config('request.jwt.claims', null, true);
  delete from public.pool_accounts where parent_context_actor_id = v_ctx;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = v_ctx);
  delete from public.money_transactions where context_actor_id = v_ctx;
  delete from public.obligations where context_actor_id = v_ctx;
  delete from public.actors where id = v_pool_actor;
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r8_c_equity_target_resolution passed';
end; $$;
revoke all on function public._smoke_r8_c_equity_target_resolution() from public, anon, authenticated;

-- 5.4 governance PULL gate: policy explícita true bloquea incluso winner_takes_all
create or replace function public._smoke_r8_c_governance_pull_gate()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_a uuid := gen_random_uuid();
  u_b uuid := gen_random_uuid();
  a_a uuid; a_b uuid;
  v_ctx uuid; v_code text;
  v_pool jsonb; v_pool_account uuid; v_pool_actor uuid;
  v_result jsonb;
begin
  a_a := public._create_person_actor_for_auth_user(u_a, 'R8C GovAdmin', '+520000000838', null);
  a_b := public._create_person_actor_for_auth_user(u_b, 'R8C GovMember', '+520000000839', null);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := ((public.create_context('_smoke_r8c Gov', 'collective', 'friend_group'))->>'context_actor_id')::uuid;
  v_code := (public.create_invite(v_ctx))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_pool := public.create_pool(v_ctx, 'Bote Gov', 'winner_takes_all', p_currency := 'MXN');
  v_pool_account := (v_pool->>'pool_account_id')::uuid;
  v_pool_actor := (v_pool->>'pool_actor_id')::uuid;
  perform public.contribute_to_pool(v_pool_account, 'cash', 100, 'MXN');

  -- Activar la policy del contexto (mismo mecanismo que los smokes R.5:
  -- update_governance_policy upsertea governance_policies)
  perform public.update_governance_policy(v_ctx, 'pool_resolve_requires_vote', 'true'::jsonb);

  -- Sin governance action aprobada → governance_required (formato exacto R.7)
  begin
    perform public.resolve_pool(v_pool_account, jsonb_build_object('winner_actor_id', a_b));
    raise exception 'r8_c gov: resolve procedió sin decisión aprobada';
  exception when sqlstate '42501' then
    if sqlerrm not like 'governance_required%' then
      raise exception 'r8_c gov: mensaje inesperado: %', sqlerrm;
    end if;
  end;
  if (select status from public.pool_accounts where id = v_pool_account) <> 'open' then
    raise exception 'r8_c gov: pool mutó pese al gate';
  end if;

  -- Override a false → desbloquea (founder: "Cena Semanal: bote sin voto")
  perform public.update_governance_policy(v_ctx, 'pool_resolve_requires_vote', 'false'::jsonb);
  v_result := public.resolve_pool(v_pool_account, jsonb_build_object('winner_actor_id', a_b));
  if (v_result->>'status') <> 'resolved' then
    raise exception 'r8_c gov: con policy=false debió resolver';
  end if;

  perform set_config('request.jwt.claims', null, true);
  delete from public.pool_accounts where parent_context_actor_id = v_ctx;
  delete from public.money_splits where transaction_id in
    (select id from public.money_transactions where context_actor_id = v_ctx);
  delete from public.money_transactions where context_actor_id = v_ctx;
  delete from public.obligations where context_actor_id = v_ctx;
  delete from public.actors where id = v_pool_actor;
  perform public._r2_cleanup_context(v_ctx, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_r8_c_governance_pull_gate passed';
end; $$;
revoke all on function public._smoke_r8_c_governance_pull_gate() from public, anon, authenticated;

-- Wrapper CI
create or replace function public._smoke_mvp2_r8_c_pool_resolution()
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
  perform public._smoke_r8_c_winner_takes_all_happy_path();
  perform public._smoke_r8_c_resolve_permission_denial();
  perform public._smoke_r8_c_equity_target_resolution();
  perform public._smoke_r8_c_governance_pull_gate();
  raise notice 'R.8.C POOL RESOLUTION: PASS — preview + resolve (winner_takes_all payout/crystallize + equity_target shares) + idempotency + already_resolved + money.settle gate + governance PULL (catalog default per-policy + policy override).';
end; $$;
revoke all on function public._smoke_mvp2_r8_c_pool_resolution() from public, anon, authenticated;

comment on function public._smoke_mvp2_r8_c_pool_resolution() is
  'R.8.C DoD: preview_pool_resolution + resolve_pool con las dos políticas MVP, payout pool→winner con splits, crystallize de pending_stake a obligations open (creditor=winner), settle de pending_pool pareadas, idempotencia por client_id, already_resolved, gate money.settle y governance PULL pool.resolve.';
