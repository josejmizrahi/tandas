-- Make _smoke_money_flow idempotent against the new on_auth_user_created
-- trigger (canonical_followup_23). The trigger now auto-creates a profile
-- row with NULL display_name when auth.users gets an INSERT; the smoke
-- function then needs to UPSERT the deterministic 'Smoke User X' label
-- instead of relying on a fresh INSERT.
--
-- Surgical patch: only the profile insert changes (line ~32 of the
-- function). Everything else is byte-for-byte identical to the prior
-- version so the smoke contract stays stable.

create or replace function public._smoke_money_flow()
 returns table(step text, ok boolean, detail text)
 language plpgsql
 security definer
 set search_path to 'public', 'auth'
as $function$
declare
  v_user_a       uuid := gen_random_uuid();
  v_user_b       uuid := gen_random_uuid();
  v_user_c       uuid := gen_random_uuid();
  v_group_id     uuid;
  v_invite_id    uuid;
  v_invite_b_code text;
  v_invite_c_id  uuid;
  v_invite_c_code text;
  v_membership_a uuid;
  v_membership_b uuid;
  v_membership_c uuid;
  v_accept_grp   uuid;
  v_tx_id        uuid;
  v_settle_id    uuid;
  v_settle_tx    uuid;
  v_obligation   public.group_obligations%rowtype;
  v_n_active     int;
  v_n_events     int;
  v_n_rep        int;
  v_n_settle_obl int;
  v_tx2          uuid;
  v_third_party_blocked boolean := false;
  v_settlement_third_party_blocked boolean := false;
begin
  if (select count(*) from public.groups) > 50 then
    raise exception 'refusing to run smoke: too many groups in db (%)', (select count(*) from public.groups);
  end if;

  insert into auth.users (id) values (v_user_a), (v_user_b), (v_user_c);
  -- ON CONFLICT UPDATE so the deterministic display_name overrides
  -- whatever the on_auth_user_created trigger inserted with NULL.
  insert into public.profiles (id, display_name) values
    (v_user_a, 'Smoke User A'), (v_user_b, 'Smoke User B'), (v_user_c, 'Smoke User C')
  on conflict (id) do update set display_name = excluded.display_name;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);

  v_group_id := public.create_group('Smoke Test ' || substr(v_user_a::text, 1, 8), null, 'friends', 'Smoke');
  step := '1.create_group'; ok := v_group_id is not null;
  detail := 'group_id=' || coalesce(v_group_id::text, 'NULL'); return next;

  select gm.id into v_membership_a from public.group_memberships gm
   where gm.group_id = v_group_id and gm.user_id = v_user_a;
  step := '1.founder_membership'; ok := v_membership_a is not null;
  detail := 'membership_a=' || coalesce(v_membership_a::text, 'NULL'); return next;

  v_invite_id := public.invite_member(v_group_id, 'smoke-b@test', null, 'member', null);
  step := '2.invite_member'; ok := v_invite_id is not null;
  detail := 'invite_id=' || coalesce(v_invite_id::text, 'NULL'); return next;

  select code into v_invite_b_code from public.group_invites where id = v_invite_id;

  v_invite_c_id := public.invite_member(v_group_id, 'smoke-c@test', null, 'member', null);
  select code into v_invite_c_code from public.group_invites where id = v_invite_c_id;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);
  select ai.group_id, ai.membership_id into v_accept_grp, v_membership_b from public.accept_invite(v_invite_b_code) ai;
  step := '3.accept_invite'; ok := v_membership_b is not null and v_accept_grp = v_group_id;
  detail := 'membership_b=' || coalesce(v_membership_b::text, 'NULL'); return next;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_c::text)::text, true);
  select ai.membership_id into v_membership_c from public.accept_invite(v_invite_c_code) ai;

  select count(*) into v_n_active from public.group_memberships gm
   where gm.group_id = v_group_id and gm.status = 'active';
  step := '3.three_active_members'; ok := v_n_active = 3;
  detail := 'active_count=' || v_n_active; return next;

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
  detail := 'amount=' || v_obligation.amount_original::text
            || ' outstanding=' || v_obligation.amount_outstanding::text
            || ' status=' || v_obligation.status; return next;

  select count(*) into v_n_events from public.group_events ge
   where ge.entity_id = v_tx_id and (ge.payload->>'authority_path') = 'self_party';
  step := '4.authority_path_self_party'; ok := v_n_events = 1;
  detail := 'self_party_events=' || v_n_events; return next;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_b::text)::text, true);

  select s.settlement_id, s.transaction_id into v_settle_id, v_settle_tx
    from public.record_settlement(
      v_group_id, v_membership_b, v_membership_a, 'member',
      50, 'MXN', 'Smoke settle', null, 'smoke-set-1'
    ) s;
  step := '5.record_settlement'; ok := v_settle_id is not null and v_settle_tx is not null;
  detail := 'settle_id=' || coalesce(v_settle_id::text, 'NULL')
            || ' tx=' || coalesce(v_settle_tx::text, 'NULL'); return next;

  select * into v_obligation from public.group_obligations where id = v_obligation.id;
  step := '5.obligation_settled'; ok := v_obligation.status = 'settled' and v_obligation.amount_outstanding = 0;
  detail := 'outstanding=' || v_obligation.amount_outstanding::text || ' status=' || v_obligation.status; return next;

  select count(*) into v_n_settle_obl from public.group_settlement_obligations gso where gso.settlement_id = v_settle_id;
  step := '5.bridge_row'; ok := v_n_settle_obl = 1;
  detail := 'bridge_rows=' || v_n_settle_obl; return next;

  select count(*) into v_n_rep from public.group_reputation_events gre
   where gre.group_id = v_group_id and gre.reputation_type = 'commitment_kept';
  step := '6.commitment_kept_emitted'; ok := v_n_rep >= 1;
  detail := 'commitment_kept_rows=' || v_n_rep; return next;

  select count(*) into v_n_events from public.group_events ge
   where ge.group_id = v_group_id
     and ge.event_type in ('group.created','member.invited','member.joined','money.expense_recorded','money.settlement_recorded');
  step := '6.events_chain'; ok := v_n_events >= 5;
  detail := 'events_chain_count=' || v_n_events; return next;

  select count(*) into v_n_events from public.group_events ge
   where ge.group_id = v_group_id
     and ge.event_type in ('money.expense_recorded','money.settlement_recorded')
     and ge.payload ? 'authority_path';
  step := '6.authority_path_present'; ok := v_n_events = 2;
  detail := 'events_with_authority_path=' || v_n_events; return next;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  v_tx2 := public.record_expense(
    v_group_id, null, 100, 'MXN', v_membership_a, 'dup', 'even',
    jsonb_build_array(
      jsonb_build_object('membership_id', v_membership_a),
      jsonb_build_object('membership_id', v_membership_b)
    ),
    false, null, 'smoke-exp-1'
  );
  step := '7.idempotency_expense'; ok := v_tx2 = v_tx_id;
  detail := 'same_id=' || (v_tx2 = v_tx_id)::text; return next;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_c::text)::text, true);
  begin
    perform public.record_expense(
      v_group_id, null, 50, 'MXN', v_membership_a, 'fraud attempt', 'even',
      jsonb_build_array(
        jsonb_build_object('membership_id', v_membership_a),
        jsonb_build_object('membership_id', v_membership_c)
      ),
      false, null, 'smoke-fraud-exp'
    );
  exception when others then
    v_third_party_blocked := true;
  end;
  step := '7.p7_third_party_blocked'; ok := v_third_party_blocked;
  detail := 'expense_third_party_without_mandate_blocked=' || v_third_party_blocked::text; return next;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_a::text)::text, true);
  perform public.record_expense(
    v_group_id, null, 60, 'MXN', v_membership_a, 'expense for P10 setup', 'even',
    jsonb_build_array(
      jsonb_build_object('membership_id', v_membership_a),
      jsonb_build_object('membership_id', v_membership_b)
    ),
    false, null, 'smoke-exp-p10'
  );

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_user_c::text)::text, true);
  begin
    perform public.record_settlement(
      v_group_id, v_membership_b, v_membership_a, 'member',
      30, 'MXN', 'fraud attempt: C declarando que B paga a A', null, 'smoke-fraud-set'
    );
  exception when others then
    v_settlement_third_party_blocked := true;
  end;
  step := '7.p10_settlement_third_party_blocked'; ok := v_settlement_third_party_blocked;
  detail := 'settlement_third_party_without_mandate_blocked=' || v_settlement_third_party_blocked::text; return next;

  step := '8.cleanup'; ok := true;
  detail := 'skipped (append-only tables block cascade delete; smoke data persists on dev)';
  return next;
  return;
end;
$function$;
