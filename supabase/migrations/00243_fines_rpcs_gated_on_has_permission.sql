-- 00232 — Fine RPCs gated on has_permission (Permission catalog v2).

alter table public.groups
  alter column roles set default
    jsonb_build_object(
      'founder', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array(
          'modifyGovernance','modifyRules','modifyMembers',
          'assignRoles','removeMember',
          'issueFine','voidFine','markFinePaid','closeAppeal','createVotes'
        )
      ),
      'member', jsonb_build_object(
        'system', true,
        'permissions', jsonb_build_array('createVotes','castVote')
      )
    );

update public.groups
   set roles = jsonb_set(
     roles,
     '{founder,permissions}',
     (
       select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
       from (
         select jsonb_array_elements_text(
           coalesce(roles -> 'founder' -> 'permissions', '[]'::jsonb)
         ) as p
         union
         select unnest(array['issueFine', 'markFinePaid']) as p
       ) merged
     )
   )
 where roles ? 'founder';

update public.templates
   set config = jsonb_set(
     config,
     '{defaultRoles,founder,permissions}',
     (
       select coalesce(jsonb_agg(distinct p), '[]'::jsonb)
       from (
         select jsonb_array_elements_text(
           coalesce(config -> 'defaultRoles' -> 'founder' -> 'permissions', '[]'::jsonb)
         ) as p
         union
         select unnest(array['issueFine', 'markFinePaid']) as p
       ) merged
     )
   )
 where config -> 'defaultRoles' -> 'founder' is not null;

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
  if not public.has_permission(p_group_id, auth.uid(), 'issueFine') then
    raise exception 'issueFine permission required'
      using errcode = '42501';
  end if;
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

revoke execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) from public, anon;
grant  execute on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) to authenticated, service_role;

comment on function public.issue_manual_fine(uuid, uuid, numeric, text, uuid, uuid) is
  'v3 (mig 00232): auth gate is has_permission(issueFine) instead of is_group_admin. Lets custom roles (e.g. treasurer) issue manual fines without being promoted to admin.';

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
  if not public.has_permission(f.group_id, uid, 'voidFine') then
    raise exception 'voidFine permission required'
      using errcode = '42501';
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

comment on function public.void_fine(uuid, text) is
  'v3 (mig 00232): auth gate is has_permission(voidFine) instead of is_group_admin. Same emit semantics as mig 00142 (priority=low + record_system_event(fineVoided)).';

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

  if not (f.user_id = auth.uid()
          or public.has_permission(f.group_id, auth.uid(), 'markFinePaid')) then
    raise exception 'not allowed'
      using errcode = '42501';
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

comment on function public.pay_fine(uuid) is
  'v3 (mig 00232): auth gate is (self-pay) OR has_permission(markFinePaid). Self-pay branch unchanged. Race-safe via SELECT FOR UPDATE + row_count check (mig 00146).';
