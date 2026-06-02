-- Smoke test E2E del lazo de dinero canónico.
-- Crea 2 auth.users sintéticos, los hace miembros del mismo grupo,
-- registra un gasto compartido, liquida la obligación, y verifica que
-- todas las tablas + eventos + reputación queden con los estados esperados.
--
-- Se invoca: select * from public._smoke_money_flow();
-- Limpia después de sí mismo via on delete cascade del grupo.

create or replace function public._smoke_money_flow()
returns table (step text, ok boolean, detail text)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_group_id     uuid;
  v_invite_id    uuid;
  v_invite_code  text;
  v_membership_a uuid;
  v_membership_b uuid;
  v_accept_grp   uuid;
  v_tx_id        uuid;
  v_settle_id    uuid;
  v_settle_tx    uuid;
  v_obligation   public.group_obligations%rowtype;
  v_n_active     int;
  v_n_events     int;
  v_n_rep        int;
  v_n_settle_obl int;
begin
  -- Defensive: never run if there are real users / groups (only on clean dev)
  if (select count(*) from public.groups) > 50 then
    raise exception 'refusing to run smoke: too many groups in db (%)', (select count(*) from public.groups);
  end if;

  -- ============================================================
  -- §0. Setup: 2 fake auth.users + profiles
  -- ============================================================
  insert into auth.users (id) values (v_user_a), (v_user_b);
  insert into public.profiles (id, display_name) values
    (v_user_a, 'Smoke User A'), (v_user_b, 'Smoke User B');

  -- ============================================================
  -- §1. user_a: create_group
  -- ============================================================
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  v_group_id := public.create_group('Smoke Test ' || substr(v_user_a::text, 1, 8), null, 'friends', 'Smoke');
  step := '1.create_group'; ok := v_group_id is not null;
  detail := 'group_id=' || coalesce(v_group_id::text, 'NULL');
  return next;

  select id into v_membership_a from public.group_memberships
   where group_id = v_group_id and user_id = v_user_a;
  step := '1.founder_membership'; ok := v_membership_a is not null;
  detail := 'membership_a=' || coalesce(v_membership_a::text, 'NULL'); return next;

  -- ============================================================
  -- §2. user_a: invite_member (by email)
  -- ============================================================
  v_invite_id := public.invite_member(v_group_id, 'smoke-b@test', null, null, 'member', null);
  step := '2.invite_member'; ok := v_invite_id is not null;
  detail := 'invite_id=' || coalesce(v_invite_id::text, 'NULL'); return next;

  select code into v_invite_code from public.group_invites where id = v_invite_id;

  -- ============================================================
  -- §3. user_b: accept_invite
  -- ============================================================
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);

  select * into v_accept_grp, v_membership_b from public.accept_invite(v_invite_code);
  step := '3.accept_invite'; ok := v_membership_b is not null and v_accept_grp = v_group_id;
  detail := 'membership_b=' || coalesce(v_membership_b::text, 'NULL'); return next;

  select count(*) into v_n_active from public.group_memberships
   where group_id = v_group_id and status = 'active';
  step := '3.two_active_members'; ok := v_n_active = 2;
  detail := 'active_count=' || v_n_active; return next;

  -- ============================================================
  -- §4. user_a: record_expense (split 50/50, b owes a $50)
  -- ============================================================
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  v_tx_id := public.record_expense(
    p_group_id              => v_group_id,
    p_resource_id           => null,
    p_amount                => 100,
    p_unit                  => 'MXN',
    p_paid_by_membership_id => v_membership_a,
    p_description           => 'Smoke expense',
    p_split_mode            => 'even',
    p_split_breakdown       => jsonb_build_array(
                                 jsonb_build_object('membership_id', v_membership_a),
                                 jsonb_build_object('membership_id', v_membership_b)
                               ),
    p_in_kind               => false,
    p_mandate_id            => null,
    p_client_id             => 'smoke-exp-1'
  );
  step := '4.record_expense'; ok := v_tx_id is not null;
  detail := 'tx_id=' || coalesce(v_tx_id::text, 'NULL'); return next;

  select * into v_obligation from public.group_obligations
   where source_transaction_id = v_tx_id
     and owed_by_membership_id = v_membership_b;
  step := '4.obligation_materialized'; ok := v_obligation.id is not null
    and v_obligation.amount_original = 50 and v_obligation.amount_outstanding = 50
    and v_obligation.status = 'open';
  detail := 'obligation amount=' || v_obligation.amount_original::text
            || ' outstanding=' || v_obligation.amount_outstanding::text
            || ' status=' || v_obligation.status; return next;

  -- ============================================================
  -- §5. user_b: record_settlement (b paga a a, cierra la obligación)
  -- ============================================================
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);

  select s.settlement_id, s.transaction_id into v_settle_id, v_settle_tx
    from public.record_settlement(
      p_group_id              => v_group_id,
      p_paid_by_membership_id => v_membership_b,
      p_paid_to_membership_id => v_membership_a,
      p_paid_to_kind          => 'member',
      p_amount                => 50,
      p_unit                  => 'MXN',
      p_notes                 => 'Smoke settle',
      p_mandate_id            => null,
      p_client_id             => 'smoke-set-1'
    ) s;
  step := '5.record_settlement'; ok := v_settle_id is not null and v_settle_tx is not null;
  detail := 'settle_id=' || coalesce(v_settle_id::text, 'NULL')
            || ' tx=' || coalesce(v_settle_tx::text, 'NULL'); return next;

  select * into v_obligation from public.group_obligations where id = v_obligation.id;
  step := '5.obligation_settled'; ok := v_obligation.status = 'settled' and v_obligation.amount_outstanding = 0;
  detail := 'outstanding=' || v_obligation.amount_outstanding::text || ' status=' || v_obligation.status; return next;

  select count(*) into v_n_settle_obl from public.group_settlement_obligations where settlement_id = v_settle_id;
  step := '5.bridge_row'; ok := v_n_settle_obl = 1;
  detail := 'bridge_rows=' || v_n_settle_obl; return next;

  -- ============================================================
  -- §6. Verify side effects: reputation + events
  -- ============================================================
  select count(*) into v_n_rep from public.group_reputation_events
   where group_id = v_group_id and reputation_type = 'commitment_kept';
  step := '6.commitment_kept_emitted'; ok := v_n_rep >= 1;
  detail := 'commitment_kept rows=' || v_n_rep; return next;

  select count(*) into v_n_events from public.group_events
   where group_id = v_group_id
     and event_type in ('group.created','member.invited','member.joined','money.expense_recorded','money.settlement_recorded');
  step := '6.events_chain'; ok := v_n_events >= 5;
  detail := 'events_chain_count=' || v_n_events; return next;

  -- Verify authority_path is in expense + settlement events
  select count(*) into v_n_events from public.group_events
   where group_id = v_group_id
     and event_type in ('money.expense_recorded','money.settlement_recorded')
     and payload ? 'authority_path';
  step := '6.authority_path_present'; ok := v_n_events = 2;
  detail := 'events with authority_path=' || v_n_events; return next;

  -- ============================================================
  -- §7. Idempotency: second call with same client_id is a no-op
  -- ============================================================
  declare v_tx2 uuid;
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
    v_tx2 := public.record_expense(
      v_group_id, null, 100, 'MXN', v_membership_a, 'dup',
      'even',
      jsonb_build_array(
        jsonb_build_object('membership_id', v_membership_a),
        jsonb_build_object('membership_id', v_membership_b)
      ),
      false, null, 'smoke-exp-1'
    );
    step := '7.idempotency_expense'; ok := v_tx2 = v_tx_id;
    detail := 'returned same id=' || (v_tx2 = v_tx_id)::text; return next;
  end;

  -- ============================================================
  -- §8. Cleanup
  -- ============================================================
  delete from public.groups where id = v_group_id;
  delete from public.profiles where id in (v_user_a, v_user_b);
  delete from auth.users where id in (v_user_a, v_user_b);

  step := '8.cleanup'; ok := true; detail := 'group + profiles + users removed'; return next;
  return;
end;
$$;

revoke execute on function public._smoke_money_flow() from anon, public;

comment on function public._smoke_money_flow() is
  'Regression test: lazo create_group → invite → accept → expense → settlement. Solo en dev. Borra todo al final.';
