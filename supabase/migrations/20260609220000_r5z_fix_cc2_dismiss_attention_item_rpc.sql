-- R.5Z.fix.CC.2.3 (2026-06-09 founder smoke) — RPC para marcar un
-- rule_attention_item como leído/descartado.
-- Solo el subject_actor (a quien va dirigido el item) o un admin del
-- contexto puede dismissear.
-- Items derivados (obligation_pay/decision_vote/settlement_open/etc.) no
-- son dismissable manualmente — se cierran cuando la acción subyacente se
-- completa (mark_completed/pay/vote/etc.).

create or replace function public.dismiss_attention_item(
  p_attention_item_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $function$
declare
  v_caller uuid := public.current_actor_id();
  v_item public.rule_attention_items%rowtype;
begin
  if v_caller is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  select * into v_item
  from public.rule_attention_items
  where id = p_attention_item_id;

  if v_item.id is null then
    raise exception 'attention item not found' using errcode = 'P0002';
  end if;

  -- Idempotent: ya resuelto/descartado
  if v_item.status <> 'open' then
    return jsonb_build_object(
      'changed', false,
      'attention_item_id', p_attention_item_id,
      'status', v_item.status,
      'noop', true
    );
  end if;

  -- Auth: el subject del item O un admin del contexto pueden dismissear.
  if v_item.subject_actor_id <> v_caller
     and not public.has_actor_authority(v_item.context_actor_id, v_caller, 'rules.manage')
  then
    raise exception 'not authorized to dismiss this attention item'
      using errcode = '42501';
  end if;

  update public.rule_attention_items
  set status = 'dismissed',
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'dismissed_by', v_caller,
        'dismissed_at', now()
      )
  where id = p_attention_item_id;

  return jsonb_build_object(
    'changed', true,
    'attention_item_id', p_attention_item_id,
    'status', 'dismissed'
  );
end;
$function$;

grant execute on function public.dismiss_attention_item(uuid) to authenticated;
