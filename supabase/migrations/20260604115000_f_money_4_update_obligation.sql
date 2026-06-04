-- F.MONEY.4 — update_obligation RPC + edit_obligation action emission.
-- Founder doctrine 2026-06-04: "editar Obligation (title/description/due_at/amount)".
--
-- Reglas:
-- - Permiso: creditor OR money.settle (admin). El debtor NO edita.
-- - Sólo obligaciones activas (open / accepted / in_progress).
-- - amount/currency sólo aplican a obligaciones kind='money'.
-- - amount > 0 si se manda.
-- - NULL = "no cambiar" (COALESCE).
-- - Emite activity obligation.updated con diff_keys.
-- - obligation_available_actions añade edit_obligation gated.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. update_obligation(...)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.update_obligation(
  p_obligation_id uuid,
  p_title text default null,
  p_description text default null,
  p_due_at timestamptz default null,
  p_amount numeric default null,
  p_currency text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_ob public.obligations%rowtype;
  v_is_creditor boolean;
  v_is_manager boolean;
  v_new_title text;
  v_new_description text;
  v_new_due_at timestamptz;
  v_new_amount numeric;
  v_new_currency text;
  v_diff_keys text[] := array[]::text[];
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_ob from public.obligations where id = p_obligation_id for update;
  if v_ob.id is null then raise exception 'obligation not found' using errcode = 'P0002'; end if;

  v_is_creditor := v_ob.creditor_actor_id = v_caller;
  v_is_manager  := v_ob.context_actor_id is not null
               and public.has_actor_authority(v_ob.context_actor_id, v_caller, 'money.settle');
  if not (v_is_creditor or v_is_manager) then
    raise exception 'not authorized to edit obligation' using errcode = '42501';
  end if;

  if v_ob.status not in ('open', 'accepted', 'in_progress') then
    raise exception 'cannot edit obligation in status %', v_ob.status using errcode = '22023';
  end if;

  -- amount/currency: rechazar si no es money kind
  if v_ob.obligation_kind <> 'money' and (p_amount is not null or p_currency is not null) then
    raise exception 'amount/currency only apply to money obligations' using errcode = '22023';
  end if;

  if p_amount is not null and p_amount <= 0 then
    raise exception 'amount must be positive' using errcode = '22023';
  end if;

  v_new_title       := coalesce(p_title, v_ob.title);
  v_new_description := coalesce(p_description, v_ob.description);
  v_new_due_at      := coalesce(p_due_at, v_ob.due_at);
  v_new_amount      := coalesce(p_amount, v_ob.amount);
  v_new_currency    := coalesce(nullif(btrim(p_currency), ''), v_ob.currency);

  if v_new_title       is distinct from v_ob.title       then v_diff_keys := array_append(v_diff_keys, 'title'); end if;
  if v_new_description is distinct from v_ob.description then v_diff_keys := array_append(v_diff_keys, 'description'); end if;
  if v_new_due_at      is distinct from v_ob.due_at      then v_diff_keys := array_append(v_diff_keys, 'due_at'); end if;
  if v_new_amount      is distinct from v_ob.amount      then v_diff_keys := array_append(v_diff_keys, 'amount'); end if;
  if v_new_currency    is distinct from v_ob.currency    then v_diff_keys := array_append(v_diff_keys, 'currency'); end if;

  if array_length(v_diff_keys, 1) is null then
    return jsonb_build_object(
      'obligation_id', p_obligation_id,
      'obligation', to_jsonb(v_ob),
      'diff_keys', '[]'::jsonb,
      'no_op', true
    );
  end if;

  update public.obligations
     set title       = v_new_title,
         description = v_new_description,
         due_at      = v_new_due_at,
         amount      = v_new_amount,
         currency    = v_new_currency
   where id = p_obligation_id;

  perform public._emit_activity(
    coalesce(v_ob.context_actor_id, v_ob.creditor_actor_id),
    v_caller,
    'obligation.updated', 'obligation', p_obligation_id,
    jsonb_build_object('diff_keys', to_jsonb(v_diff_keys))
  );

  return jsonb_build_object(
    'obligation_id', p_obligation_id,
    'obligation', (select to_jsonb(o) from public.obligations o where o.id = p_obligation_id),
    'diff_keys', to_jsonb(v_diff_keys),
    'no_op', false
  );
end; $$;

revoke all on function public.update_obligation(uuid, text, text, timestamptz, numeric, text) from public, anon;
grant execute on function public.update_obligation(uuid, text, text, timestamptz, numeric, text) to authenticated, service_role;

comment on function public.update_obligation(uuid, text, text, timestamptz, numeric, text) is
  'F.MONEY.4: edit obligation canónico. Acreedor o money.settle. Sólo obligaciones activas.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. obligation_available_actions — añadir edit_obligation
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.obligation_available_actions(p_obligation_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_ob public.obligations%rowtype;
  v_active boolean;
  v_is_debtor boolean;
  v_is_creditor boolean;
  v_is_manager boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_ob from public.obligations where id = p_obligation_id;
  if v_ob.id is null then return '[]'::jsonb; end if;

  v_active := v_ob.status in ('open', 'accepted', 'in_progress');
  v_is_debtor := p_actor_id = v_ob.debtor_actor_id;
  v_is_creditor := p_actor_id = v_ob.creditor_actor_id;
  v_is_manager := v_ob.context_actor_id is not null
              and public.has_actor_authority(v_ob.context_actor_id, p_actor_id, 'money.settle');

  if v_ob.obligation_kind = 'money' and v_active then
    v_actions := v_actions || public._aa('pay', 'Pagar', 'obligations',
      v_is_debtor, case when v_is_debtor then 'Eres el deudor de esta obligación'
                        else 'Solo el deudor puede pagar' end);
  end if;

  if v_ob.obligation_kind <> 'money' and v_active then
    v_actions := v_actions || public._aa('mark_completed', 'Marcar como cumplida', 'obligations',
      v_is_debtor or v_is_creditor or v_is_manager,
      case when v_is_debtor or v_is_creditor or v_is_manager then 'Participas en esta obligación'
           else 'Solo deudor, acreedor o un administrador pueden marcarla' end);
  end if;

  if v_ob.status in ('open', 'accepted', 'in_progress', 'completed') then
    v_actions := v_actions || public._aa('dispute', 'Disputar', 'obligations',
      v_is_debtor or v_is_creditor,
      case when v_is_debtor or v_is_creditor then 'Eres parte de la obligación'
           else 'Solo deudor o acreedor pueden disputar' end);
  end if;

  if v_active then
    v_actions := v_actions || public._aa('forgive', 'Condonar', 'obligations',
      v_is_creditor, case when v_is_creditor then 'Eres el acreedor y puedes condonar'
                          else 'Solo el acreedor puede condonar' end);
  end if;

  if v_active then
    v_actions := v_actions || public._aa('cancel', 'Cancelar', 'obligations',
      v_is_creditor or v_is_manager,
      case when v_is_creditor or v_is_manager then 'Eres acreedor o administrador'
           else 'Solo el acreedor o un administrador pueden cancelar' end);
  end if;

  -- F.MONEY.4 — edit_obligation: acreedor o money.settle, sólo si activa.
  if v_active then
    v_actions := v_actions || public._aa('edit_obligation', 'Editar obligación', 'obligations',
      v_is_creditor or v_is_manager,
      case when v_is_creditor then 'Eres el acreedor y puedes editar'
           when v_is_manager then 'Tienes permiso para administrar dinero'
           else 'Solo el acreedor o un administrador pueden editar la obligación' end);
  end if;

  return v_actions;
end; $$;

revoke all on function public.obligation_available_actions(uuid, uuid) from public, anon;
grant execute on function public.obligation_available_actions(uuid, uuid) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Smoke F.MONEY.4
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_f_money_4_update_obligation()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx uuid;
  v_ob uuid;
  v_result jsonb;
  v_aa jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José F.M.4', '+5210000300');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David F.M.4', '+5210000301');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Grupo F.M.4', 'collective', 'friend_group'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);

  -- Jose crea una multa para David (Jose creditor, David debtor).
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ob := (public.record_fine(v_ctx::uuid, a_david, 200, 'MXN', 'late_arrival'))->>'obligation_id';

  -- 1. Acreedor edita amount + description
  v_result := public.update_obligation(v_ob::uuid, null, 'Llegó 20 min tarde', null, 250);
  if (v_result->>'no_op')::boolean then raise exception 'F.M.4 FAIL 1: no_op cuando había cambios'; end if;
  if (v_result->'obligation'->>'amount')::numeric <> 250 then
    raise exception 'F.M.4 FAIL 1: amount no actualizó';
  end if;

  -- 2. No-op si nada cambia
  v_result := public.update_obligation(v_ob::uuid);
  if not (v_result->>'no_op')::boolean then raise exception 'F.M.4 FAIL 2'; end if;

  -- 3. amount <= 0 → 22023
  begin
    perform public.update_obligation(v_ob::uuid, null, null, null, 0);
    raise exception 'F.M.4 FAIL 3';
  exception when sqlstate '22023' then null; end;

  -- 4. David (debtor) no puede editar
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  begin
    perform public.update_obligation(v_ob::uuid, null, null, null, 100);
    raise exception 'F.M.4 FAIL 4';
  exception when sqlstate '42501' then null; end;

  -- 5. edit_obligation aparece enabled para acreedor
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_aa := public.obligation_available_actions(v_ob::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_aa) e
                 where e->>'action_key' = 'edit_obligation' and (e->>'enabled')::boolean) then
    raise exception 'F.M.4 FAIL 5: acreedor no tiene edit_obligation enabled';
  end if;

  -- 6. edit_obligation aparece disabled para david (debtor)
  v_aa := public.obligation_available_actions(v_ob::uuid, a_david);
  if not exists (select 1 from jsonb_array_elements(v_aa) e
                 where e->>'action_key' = 'edit_obligation' and not (e->>'enabled')::boolean) then
    raise exception 'F.M.4 FAIL 6: edit_obligation para deudor debería estar disabled';
  end if;

  -- 7. Tras cancelar (UPDATE directo — no hay cancel_obligation RPC), edit_obligation desaparece
  update public.obligations set status = 'cancelled' where id = v_ob::uuid;
  v_aa := public.obligation_available_actions(v_ob::uuid, a_jose);
  if exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'edit_obligation') then
    raise exception 'F.M.4 FAIL 7: edit_obligation aparece en obligación cancelada';
  end if;

  -- 8. Editar una cancelada → 22023
  begin
    perform public.update_obligation(v_ob::uuid, null, null, null, 500);
    raise exception 'F.M.4 FAIL 8';
  exception when sqlstate '22023' then null; end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'F.MONEY.4 update_obligation: PASS (8/8)';
end; $$;

revoke all on function public._smoke_f_money_4_update_obligation() from public, anon, authenticated;

create or replace function public._smoke_mvp2_f_money_4_update_obligation()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_f_money_4_update_obligation(); end; $$;
revoke all on function public._smoke_mvp2_f_money_4_update_obligation() from public, anon, authenticated;

comment on function public._smoke_mvp2_f_money_4_update_obligation() is
  'Wrapper CI del smoke F.MONEY.4 — update_obligation + edit_obligation action.';

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'update_obligation') then
    raise exception 'F.MONEY.4 DoD: falta update_obligation';
  end if;
  raise notice 'F.MONEY.4 DoD: update_obligation + edit_obligation action emission';
end $$;
