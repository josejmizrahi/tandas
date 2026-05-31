-- P3: cast_vote sin p_weight. Peso siempre = 1 en V1; calculado server-side.
drop function if exists public.cast_vote(uuid, uuid, text, numeric, text);

create or replace function public.cast_vote(
  p_decision_id uuid,
  p_option_id   uuid default null,
  p_vote_value  text default null,
  p_reason      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_d        public.group_decisions%rowtype;
  v_voter    uuid;
  v_weight   numeric;
  v_id       uuid;
  v_event    uuid;
begin
  select * into v_d from public.group_decisions where id = p_decision_id;
  if v_d.id is null then raise exception 'decision not found'; end if;
  if v_d.status <> 'open' then raise exception 'decision is not open'; end if;
  if v_d.closes_at is not null and v_d.closes_at < now() then
    raise exception 'voting window closed';
  end if;

  v_voter := (select gm.id from public.group_memberships gm
              where gm.group_id = v_d.group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_voter is null then
    raise exception 'caller is not an active member of group %', v_d.group_id;
  end if;

  -- P3: weight calculated server-side. V1: always 1. Future: derive from
  -- decision.method + roles + mandates + equity if applicable.
  v_weight := 1;

  insert into public.group_votes (
    group_id, decision_id, voter_membership_id, option_id, vote_value, weight, reason
  ) values (
    v_d.group_id, p_decision_id, v_voter, p_option_id, p_vote_value, v_weight, p_reason
  ) returning id into v_id;

  -- Silent canonical write: ver §X del contrato (no expone valor del voto al group_events).
  select rse.uuid_id into v_event from public.record_system_event(
    v_d.group_id, 'decision.vote_cast', 'decision', p_decision_id, null,
    jsonb_build_object('voter_membership_id', v_voter, 'authority_path', 'self_party')
  ) rse;
  perform public.evaluate_rules_for_event(v_event, 'sync');

  return v_id;
end;
$$;

-- P4: verify_contribution usa contribution.verify (NO records.read) + self-check.
create or replace function public.verify_contribution(
  p_contribution_id uuid,
  p_outcome         text,
  p_note            text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c       public.group_contributions%rowtype;
  v_actor_m uuid;
  v_event   uuid;
begin
  if p_outcome not in ('verified','rejected') then raise exception 'invalid outcome'; end if;
  select * into v_c from public.group_contributions where id = p_contribution_id for update;
  if v_c.id is null then raise exception 'contribution not found'; end if;

  v_actor_m := (select gm.id from public.group_memberships gm
                where gm.group_id = v_c.group_id and gm.user_id = auth.uid() and gm.status = 'active');
  if v_actor_m is null then
    raise exception 'caller is not an active member of group %', v_c.group_id;
  end if;

  -- P4 self-check: verifier no puede ser el subject
  if v_actor_m = v_c.membership_id then
    raise exception 'verifier cannot be the contribution subject';
  end if;

  perform public.assert_permission(v_c.group_id, 'contribution.verify');

  update public.group_contributions
     set status = p_outcome, verified_by = auth.uid(),
         metadata = metadata || jsonb_build_object('verifier_note', p_note)
   where id = p_contribution_id;

  if p_outcome = 'verified' then
    insert into public.group_reputation_events (
      group_id, subject_membership_id, actor_membership_id,
      reputation_type, reason, evidence_entity_kind, evidence_entity_id
    ) values (
      v_c.group_id, v_c.membership_id, v_actor_m,
      'contribution_recognized', p_note, 'contribution', p_contribution_id
    );
  end if;

  select rse.uuid_id into v_event from public.record_system_event(
    v_c.group_id, 'contribution.' || p_outcome, 'contribution', p_contribution_id, p_note,
    jsonb_build_object('authority_path', 'direct_permission')
  ) rse;
  perform public.evaluate_rules_for_event(v_event, 'sync');
end;
$$;

-- P5: reverse_transaction usa money.transaction.reverse + dependent guard.
create or replace function public.reverse_transaction(
  p_transaction_id uuid,
  p_reason         text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tx              public.group_resource_transactions%rowtype;
  v_actor_m         uuid;
  v_authority_path  text;
  v_new             uuid;
  v_dependent_obl   int;
  v_dependent_settle int;
begin
  select * into v_tx from public.group_resource_transactions where id = p_transaction_id;
  if v_tx.id is null then raise exception 'transaction not found'; end if;

  v_actor_m := (select gm.id from public.group_memberships gm
                where gm.group_id = v_tx.group_id and gm.user_id = auth.uid() and gm.status = 'active');

  -- Authority: self_party = el actor registró la original; direct_permission = money.transaction.reverse
  v_authority_path := public._resolve_authority_path(
    p_group_id         => v_tx.group_id,
    p_actor_membership => v_actor_m,
    p_is_self_party    => (v_tx.recorded_by = auth.uid()),
    p_mandate_id       => null,
    p_permission       => 'money.transaction.reverse'
  );

  -- P5 dependent guard: no se puede revertir una transaction que materializó obligations
  -- o que fue ledger entry de un settlement, porque dejaría artifacts vivos.
  select count(*) into v_dependent_obl from public.group_obligations o
   where o.source_transaction_id = p_transaction_id;
  select count(*) into v_dependent_settle from public.group_settlements gs
   where gs.ledger_entry_id = p_transaction_id;

  if v_dependent_obl > 0 or v_dependent_settle > 0 then
    raise exception 'transaction has dependent obligations or settlements; use domain-specific reversal';
  end if;

  -- Rechaza reversal de reversals
  if v_tx.transaction_type = 'reversal' then
    raise exception 'cannot reverse a reversal entry';
  end if;
  if v_tx.reversed_entry_id is not null then
    raise exception 'transaction already reversed';
  end if;

  insert into public.group_resource_transactions (
    group_id, resource_id, transaction_type,
    from_membership_id, to_membership_id, paid_by_membership_id,
    amount, unit, source_entity_kind, source_entity_id,
    reversed_entry_id, description, recorded_by
  ) values (
    v_tx.group_id, v_tx.resource_id, 'reversal',
    v_tx.to_membership_id, v_tx.from_membership_id, v_tx.paid_by_membership_id,
    v_tx.amount, v_tx.unit, 'manual', null,
    p_transaction_id, p_reason, auth.uid()
  ) returning id into v_new;

  perform public.record_system_event(
    v_tx.group_id, 'money.transaction_reversed', 'transaction', p_transaction_id, p_reason,
    jsonb_build_object(
      'reversal_id', v_new,
      'reason', p_reason,
      'authority_path', v_authority_path
    )
  );
  return v_new;
end;
$$;

-- P6: invite_member drop p_role_key. V1 simple: accept_invite asigna default role;
-- el rol se eleva después vía assign_role_to_member.
drop function if exists public.invite_member(uuid, text, text, text, text, text);

create or replace function public.invite_member(
  p_group_id          uuid,
  p_email             text default null,
  p_phone             text default null,
  p_membership_type   text default 'member',
  p_message           text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite_id  uuid;
  v_code       text;
  v_token_hash text;
  v_user_id    uuid;
begin
  perform public.assert_permission(p_group_id, 'members.invite');
  if p_email is null and p_phone is null then
    raise exception 'invite requires email or phone';
  end if;

  v_code       := upper(substring(encode(extensions.gen_random_bytes(8), 'hex') for 8));
  v_token_hash := encode(extensions.digest(v_code || p_group_id::text, 'sha256'), 'hex');

  select p.id into v_user_id from public.profiles p
   where (p_phone is not null and lower(coalesce(p.phone, '')) = lower(p_phone))
   limit 1;

  insert into public.group_invites (
    group_id, email, phone, invited_user_id, invited_by,
    status, token_hash, code, expires_at, metadata
  ) values (
    p_group_id, p_email, p_phone, v_user_id, auth.uid(),
    'pending', v_token_hash, v_code, now() + interval '14 days',
    jsonb_build_object('message', p_message, 'membership_type', p_membership_type)
  )
  returning id into v_invite_id;

  perform public.record_system_event(
    p_group_id, 'member.invited', 'invite', v_invite_id, 'Invitación creada',
    jsonb_build_object('email', p_email, 'phone', p_phone, 'authority_path', 'direct_permission')
  );

  insert into public.notifications_outbox (group_id, recipient_user_id, category, payload)
  select p_group_id, v_user_id, 'member.invited',
         jsonb_build_object('invite_id', v_invite_id, 'group_id', p_group_id, 'code', v_code)
  where v_user_id is not null;

  return v_invite_id;
end;
$$;
