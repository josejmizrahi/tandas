-- 00089_apply_pending_change.sql
-- Apply pending governance changes when a rule_change vote resolves passed (Phase 1).
--
-- When governance routes an action through `vote_required`, iOS records the
-- proposed change as a `rule_change` vote whose `payload` carries an envelope
-- of the form:
--
--   {
--     "op":               'rule.toggle' | 'rule.update_amount' | 'rule.delete' | 'rule.create',
--     "target_rule_id":   <uuid | null>,    -- null for rule.create
--     "before":           <jsonb>,          -- pre-state snapshot (for audit, ignored here)
--     "after":            <jsonb>           -- target state. Shape depends on op:
--       rule.toggle        → { is_active: bool }
--       rule.update_amount → { amount: int }
--       rule.delete        → {}             -- (target_rule_id carries the id)
--       rule.create        → { name, is_active, trigger, conditions, consequences,
--                              slug?, module_key?, resource_id? }
--     "resolution":       'passed' | 'failed' | 'quorum_failed'  -- set by finalize_vote (mig 00020)
--   }
--
-- `apply_pending_change(p_vote_id)` is fired from the
-- `votes_apply_on_pass_trg` AFTER UPDATE trigger below as soon as a
-- `rule_change` vote transitions into a resolved+passed terminal state.
-- The function is idempotent: re-firing on an already-applied vote
-- short-circuits via a `system_events` probe (event_type
-- 'pendingChangeApplied' + payload.vote_id == p_vote_id).
--
-- Project conventions adopted (verified pre-flight, deviations from plan doc):
--   * `public.record_system_event(p_group_id, p_event_type,
--     p_resource_id, p_member_id, p_payload)` (mig 00014) takes five named
--     params with `resource_id`/`member_id` defaulting to null — used here
--     with positional + named args.
--   * `public.rules` has NO `archived_at` column anywhere in the migration
--     history. `rule.delete` therefore only flips `is_active = false` and
--     bumps `updated_at`; it does NOT set `archived_at`.
--   * `public.rules.trigger jsonb NOT NULL` was restored in mig 00059 — the
--     `rule.create` envelope MUST carry a `trigger` jsonb, otherwise the
--     insert raises. `name` is nullable (mig 00014); we coalesce safely.
--     `slug`, `module_key`, `resource_id` are nullable — read with `->>`
--     and cast.
--   * `public.votes` columns probed in the trigger are present in mig
--     00020: `id, group_id, vote_type, status, counts (jsonb), payload`.
--     `counts->>'resolution'` is populated by `finalize_vote` (also mig
--     00020) — that is the canonical channel for the resolution string.
--   * Function is `SECURITY DEFINER` with locked `search_path = public` so
--     the trigger (running as table owner) can update `rules` and insert
--     into `system_events` without inheriting caller GUCs.
--   * Direct EXECUTE is revoked from public/anon and NOT granted to
--     authenticated — the trigger is the only legitimate caller. SECURITY
--     DEFINER bypasses RLS internally so no extra grants are needed.

create or replace function public.apply_pending_change(p_vote_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote     public.votes%rowtype;
  v_op       text;
  v_target   uuid;
  v_before   jsonb;
  v_after    jsonb;
  v_applied  boolean;
begin
  -- 1. Load the vote row.
  select * into v_vote from public.votes where id = p_vote_id;
  if not found then
    raise exception 'apply_pending_change: vote % not found', p_vote_id
      using errcode = '02000';
  end if;

  -- 2. No-op guards: must be resolved + passed.
  if v_vote.status <> 'resolved' then
    return;
  end if;
  if coalesce(v_vote.counts->>'resolution', '') <> 'passed' then
    return;
  end if;

  -- 3. V1 only applies rule_change votes. Other vote_types (fine_appeal,
  --    member_removal, fund_withdrawal, …) are handled elsewhere.
  if v_vote.vote_type <> 'rule_change' then
    return;
  end if;

  -- 4. Idempotency probe. If we've already emitted pendingChangeApplied
  --    for this vote, return silently. The trigger guard already filters
  --    most re-fires, but this is the authoritative replay shield (e.g.
  --    if the function is invoked manually for backfill / repair).
  select exists(
    select 1
      from public.system_events se
     where se.group_id   = v_vote.group_id
       and se.event_type = 'pendingChangeApplied'
       and (se.payload->>'vote_id')::uuid = p_vote_id
  ) into v_applied;

  if v_applied then
    return;
  end if;

  -- 5. Decode the envelope.
  v_op     := v_vote.payload->>'op';
  v_target := nullif(v_vote.payload->>'target_rule_id', '')::uuid;
  v_before := v_vote.payload->'before';
  v_after  := v_vote.payload->'after';

  if v_op is null then
    raise exception 'apply_pending_change: vote % payload missing op', p_vote_id
      using errcode = '22023';
  end if;

  -- 6. Dispatch.
  if v_op = 'rule.toggle' then
    if v_target is null then
      raise exception 'apply_pending_change: rule.toggle requires target_rule_id'
        using errcode = '22023';
    end if;
    update public.rules
       set is_active  = coalesce((v_after->>'is_active')::boolean, true),
           updated_at = now()
     where id = v_target;

  elsif v_op = 'rule.update_amount' then
    if v_target is null then
      raise exception 'apply_pending_change: rule.update_amount requires target_rule_id'
        using errcode = '22023';
    end if;
    update public.rules
       set consequences = jsonb_build_array(
             jsonb_build_object(
               'type',   'fine',
               'config', jsonb_build_object('amount', (v_after->>'amount')::int)
             )
           ),
           updated_at = now()
     where id = v_target;

  elsif v_op = 'rule.delete' then
    if v_target is null then
      raise exception 'apply_pending_change: rule.delete requires target_rule_id'
        using errcode = '22023';
    end if;
    -- NOTE: rules.archived_at does not exist (pre-flight). Soft-delete is
    -- expressed solely via is_active = false. If a future migration adds
    -- archived_at, extend this branch.
    update public.rules
       set is_active  = false,
           updated_at = now()
     where id = v_target;

  elsif v_op = 'rule.create' then
    -- All NOT NULL platform-shape columns must be present on v_after:
    --   trigger (jsonb NOT NULL — mig 00059)
    --   conditions / consequences default to '[]' if absent.
    --   is_active defaults to true if absent.
    --   name is nullable but the envelope normally carries it.
    insert into public.rules (
      group_id,
      name,
      slug,
      is_active,
      trigger,
      conditions,
      consequences,
      module_key,
      resource_id
    )
    values (
      v_vote.group_id,
      v_after->>'name',
      nullif(v_after->>'slug', ''),
      coalesce((v_after->>'is_active')::boolean, true),
      coalesce(v_after->'trigger', jsonb_build_object('eventType', 'manual', 'config', '{}'::jsonb)),
      coalesce(v_after->'conditions',   '[]'::jsonb),
      coalesce(v_after->'consequences', '[]'::jsonb),
      nullif(v_after->>'module_key',   ''),
      nullif(v_after->>'resource_id',  '')::uuid
    );

  else
    raise exception 'apply_pending_change: unknown op %', v_op
      using errcode = '22023';
  end if;

  -- 7. Emit the audit event so subsequent invocations short-circuit.
  perform public.record_system_event(
    p_group_id    => v_vote.group_id,
    p_event_type  => 'pendingChangeApplied',
    p_resource_id => v_target,            -- null for rule.create; that's fine
    p_member_id   => null,
    p_payload     => jsonb_build_object(
      'vote_id',        p_vote_id,
      'op',             v_op,
      'target_rule_id', v_target,
      'after',          v_after
    )
  );
end;
$$;

comment on function public.apply_pending_change(uuid) is
  'Applies a rule_change vote''s payload envelope to public.rules when the vote resolves passed. Dispatches by payload.op (rule.toggle | rule.update_amount | rule.delete | rule.create). Idempotent via the pendingChangeApplied system event. Called from votes_apply_on_pass_trg.';

revoke execute on function public.apply_pending_change(uuid) from public, anon;
-- Not granted to authenticated: only the trigger (table owner via
-- SECURITY DEFINER) calls this function. Direct invocation is reserved
-- for migration/backfill scripts run as database owner.

-- =============================================================================
-- Trigger: votes_apply_on_pass_trg
-- =============================================================================
-- Fires AFTER UPDATE on public.votes. Guard conditions:
--   * NEW.status = 'resolved'
--   * (NEW.counts->>'resolution') = 'passed'
--   * NEW.vote_type = 'rule_change'
--   * OLD was NOT already in the resolved+passed terminal state — prevents
--     benign updates (e.g. payload patches, comment fields) on an
--     already-applied vote from re-invoking the function. The
--     `apply_pending_change` idempotency probe is the second line of
--     defense.

create or replace function public.votes_apply_on_pass()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'resolved'
     and (NEW.counts->>'resolution') = 'passed'
     and NEW.vote_type = 'rule_change'
     and (
           OLD.status <> 'resolved'
        or (OLD.counts->>'resolution') is distinct from 'passed'
         )
  then
    perform public.apply_pending_change(NEW.id);
  end if;
  return NEW;
end;
$$;

comment on function public.votes_apply_on_pass() is
  'Trigger function: invokes apply_pending_change(NEW.id) when a rule_change vote transitions into resolved+passed. Idempotent at both trigger and function level.';

drop trigger if exists votes_apply_on_pass_trg on public.votes;

create trigger votes_apply_on_pass_trg
  after update on public.votes
  for each row
  execute function public.votes_apply_on_pass();
