-- Rollback for 00233_fines_rpcs_gated_on_has_permission.sql
--
-- Restores the pre-00232 RPC bodies that gated on is_group_admin.
-- Catalog backfill (issueFine + markFinePaid added to groups.roles
-- and templates.config.defaultRoles) is left in place: it is additive
-- and harmless, and rolling it back would risk dropping permissions a
-- founder may have intentionally edited after apply. The column
-- DEFAULT is also left at the v2 shape — new groups will simply seed
-- with permissions that aren't enforced post-rollback (no-op).
--
-- If a hard rollback of the catalog is also required, do it manually
-- with care after auditing groups.roles per-group.

-- Restore issue_manual_fine body from mig 00155.
create or replace function public.issue_manual_fine(
  p_group_id    uuid,
  p_user_id     uuid,
  p_amount      numeric,
  p_reason      text,
  p_rule_id     uuid default null,
  p_resource_id uuid default null
)
returns public.fines
language plpgsql
security definer
set search_path = public
as $$
declare
  f             public.fines;
  r             public.rules;
  v_snapshot    jsonb;
  v_member_id   uuid;
begin
  if auth.uid() is null then raise exception 'auth required'; end if;
  if not public.is_group_admin(p_group_id, auth.uid()) then raise exception 'admin only'; end if;
  if not public.is_group_member(p_group_id, p_user_id) then raise exception 'target user not a member'; end if;
  if p_amount < 0 then raise exception 'amount must be non-negative'; end if;
  if length(coalesce(p_reason, '')) < 2 then raise exception 'reason required'; end if;

  if p_rule_id is not null then
    select * into r from public.rules where id = p_rule_id;
    if found then
      v_snapshot := jsonb_build_object(
        'trigger',     coalesce(r.trigger, to_jsonb(r.conditions)),
        'action',      coalesce(r.action,  to_jsonb(r.consequences)),
        'rule_title',  coalesce(r.title,   r.name),
        'rule_slug',   r.slug
      );
    end if;
  end if;

  insert into public.fines (
    group_id, user_id, amount, reason, rule_id, resource_id,
    auto_generated, issued_by, rule_snapshot
  )
  values (
    p_group_id, p_user_id, p_amount, p_reason, p_rule_id, p_resource_id,
    false, auth.uid(), v_snapshot
  )
  returning * into f;

  select id into v_member_id from public.group_members
   where group_id = f.group_id and user_id = f.user_id limit 1;

  insert into public.ledger_entries (
    group_id, resource_id, type, amount_cents, currency,
    from_member_id, to_member_id, metadata,
    occurred_at, recorded_at, recorded_by
  )
  values (
    f.group_id, f.resource_id, 'fine_officialized', (f.amount * 100)::bigint, 'MXN',
    v_member_id, null,
    jsonb_build_object('fine_id', f.id, 'rule_id', f.rule_id, 'via', 'issue_manual_fine'),
    now(), now(), auth.uid()
  );

  return f;
end;
$$;

-- Restore void_fine body from mig 00142.
create or replace function public.void_fine(p_fine_id uuid, p_reason text default null)
returns public.fines
language plpgsql security definer set search_path = public as $$
declare
  f public.fines;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select * into f from public.fines where id = p_fine_id;
  if f.id is null then raise exception 'fine not found'; end if;
  if not public.is_group_admin(f.group_id, uid) then
    raise exception 'only admins can void fines';
  end if;
  if f.status not in ('proposed','officialized') then
    raise exception 'cannot void fine with status %', f.status;
  end if;
  if length(coalesce(p_reason, '')) < 2 then
    raise exception 'reason required';
  end if;

  update public.fines
     set status = 'voided',
         waived = true,
         waived_at = now(),
         waived_reason = p_reason
   where id = p_fine_id
   returning * into f;

  insert into public.user_actions (
    user_id, group_id, action_type, reference_id,
    title, body, priority
  ) values (
    f.user_id, f.group_id, 'fineVoided', f.id,
    'Multa anulada por admin: $' || trim(to_char(f.amount, 'FM999G999D00')),
    p_reason,
    'low'
  );

  perform public.record_system_event(
    f.group_id,
    'fineVoided',
    f.id,
    null,
    jsonb_build_object(
      'amount', f.amount,
      'reason', p_reason,
      'voided_by_user_id', uid
    )
  );

  return f;
end;
$$;

-- Restore pay_fine body from mig 00146.
create or replace function public.pay_fine(p_fine_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.fines;
  g public.groups;
  v_updated int;
begin
  select * into f
    from public.fines
   where id = p_fine_id
   for update;

  if not found then
    raise exception 'fine not found';
  end if;

  select * into g from public.groups where id = f.group_id;

  if not (f.user_id = auth.uid() or public.is_group_admin(f.group_id, auth.uid())) then
    raise exception 'not allowed';
  end if;

  if f.paid then return; end if;

  update public.fines
     set paid          = true,
         paid_at       = now(),
         paid_to_fund  = g.fund_enabled
   where id   = p_fine_id
     and paid = false;

  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    return;
  end if;

  if g.fund_enabled then
    update public.groups
       set fund_balance = fund_balance + f.amount
     where id = g.id;
  end if;
end;
$$;
