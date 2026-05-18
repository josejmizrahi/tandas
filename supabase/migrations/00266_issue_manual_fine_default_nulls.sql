-- Mig 00230: add DEFAULT NULL to issue_manual_fine.p_rule_id.
--
-- Audit (sweep following mig 00265) found one remaining RPC whose
-- signature trips the same Swift Codable + PostgREST overload
-- resolution trap that broke record_ledger_entry:
--
--   * FineRepository.issueManual() always passes `p_rule_id: nil`
--     (manual fines are by definition not rule-derived). With the
--     synthesized Codable encoder's encodeIfPresent semantics, that
--     key is OMITTED from the JSON body. PostgREST then looks for a
--     5-arg overload of issue_manual_fine that doesn't exist and
--     returns 404 → the Fines UI surfaces a generic "no se pudo
--     emitir la multa" error.
--
-- The function body already guards `p_rule_id` with
--   if p_rule_id is not null then ... end if
-- so NULL is fully supported semantically. The fix is to advertise
-- the default at the signature level so PostgREST resolves the
-- 5-key call shape to the 6-arg function.
--
-- `p_resource_id uuid DEFAULT NULL` already had the right shape
-- (mig 00102 / 00148 / 00150 lineage) so no other args change.
--
-- Pure-additive DDL — existing 6-key callers (server-side or any
-- future SDK passing all keys explicitly) are unaffected.

BEGIN;

CREATE OR REPLACE FUNCTION public.issue_manual_fine(
  p_group_id    uuid,
  p_user_id     uuid,
  p_amount      numeric,
  p_reason      text,
  p_rule_id     uuid DEFAULT NULL,
  p_resource_id uuid DEFAULT NULL
)
RETURNS public.fines
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;

COMMIT;
