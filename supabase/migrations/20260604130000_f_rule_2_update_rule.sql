-- F.RULE.2 — update_rule RPC.
-- Founder doctrine 2026-06-04: "editar Rule (title/trigger/conditions/consequences)".
--
-- Reglas:
-- - Permiso: rules.manage en el contexto de la regla.
-- - Sólo reglas no archivadas (archived_at IS NULL).
-- - NULL = "no cambiar" (COALESCE).
-- - Validación: severity en [1, 5]; status en {active, paused}.
-- - Emite activity rule.updated con diff_keys.

create or replace function public.update_rule(
  p_rule_id uuid,
  p_title text default null,
  p_body text default null,
  p_trigger_event_type text default null,
  p_condition_tree jsonb default null,
  p_consequences jsonb default null,
  p_target_scope text default null,
  p_target_filter jsonb default null,
  p_severity integer default null,
  p_status text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_r public.rules%rowtype;
  v_new_title text;
  v_new_body text;
  v_new_trigger text;
  v_new_condition jsonb;
  v_new_consequences jsonb;
  v_new_scope text;
  v_new_filter jsonb;
  v_new_severity integer;
  v_new_status text;
  v_diff_keys text[] := array[]::text[];
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_r from public.rules where id = p_rule_id for update;
  if v_r.id is null then raise exception 'rule not found' using errcode = 'P0002'; end if;

  if not public.has_actor_authority(v_r.context_actor_id, v_caller, 'rules.manage') then
    raise exception 'not authorized to edit rule' using errcode = '42501';
  end if;

  if v_r.archived_at is not null then
    raise exception 'cannot edit archived rule' using errcode = '22023';
  end if;

  v_new_title       := coalesce(nullif(btrim(p_title), ''), v_r.title);
  v_new_body        := coalesce(p_body, v_r.body);
  v_new_trigger     := coalesce(nullif(btrim(p_trigger_event_type), ''), v_r.trigger_event_type);
  v_new_condition   := coalesce(p_condition_tree, v_r.condition_tree);
  v_new_consequences:= coalesce(p_consequences, v_r.consequences);
  v_new_scope       := coalesce(nullif(btrim(p_target_scope), ''), v_r.target_scope);
  v_new_filter      := coalesce(p_target_filter, v_r.target_filter);
  v_new_severity    := coalesce(p_severity, v_r.severity);
  v_new_status      := coalesce(nullif(btrim(p_status), ''), v_r.status);

  if v_new_severity < 1 or v_new_severity > 5 then
    raise exception 'severity must be between 1 and 5' using errcode = '22023';
  end if;
  if v_new_status not in ('active', 'paused') then
    raise exception 'status must be active or paused' using errcode = '22023';
  end if;

  if v_new_title        is distinct from v_r.title              then v_diff_keys := array_append(v_diff_keys, 'title'); end if;
  if v_new_body         is distinct from v_r.body               then v_diff_keys := array_append(v_diff_keys, 'body'); end if;
  if v_new_trigger      is distinct from v_r.trigger_event_type then v_diff_keys := array_append(v_diff_keys, 'trigger_event_type'); end if;
  if v_new_condition    is distinct from v_r.condition_tree     then v_diff_keys := array_append(v_diff_keys, 'condition_tree'); end if;
  if v_new_consequences is distinct from v_r.consequences       then v_diff_keys := array_append(v_diff_keys, 'consequences'); end if;
  if v_new_scope        is distinct from v_r.target_scope       then v_diff_keys := array_append(v_diff_keys, 'target_scope'); end if;
  if v_new_filter       is distinct from v_r.target_filter      then v_diff_keys := array_append(v_diff_keys, 'target_filter'); end if;
  if v_new_severity     is distinct from v_r.severity           then v_diff_keys := array_append(v_diff_keys, 'severity'); end if;
  if v_new_status       is distinct from v_r.status             then v_diff_keys := array_append(v_diff_keys, 'status'); end if;

  if array_length(v_diff_keys, 1) is null then
    return jsonb_build_object(
      'rule_id', p_rule_id,
      'rule', to_jsonb(v_r),
      'diff_keys', '[]'::jsonb,
      'no_op', true
    );
  end if;

  update public.rules
     set title              = v_new_title,
         body               = v_new_body,
         trigger_event_type = v_new_trigger,
         condition_tree     = v_new_condition,
         consequences       = v_new_consequences,
         target_scope       = v_new_scope,
         target_filter      = v_new_filter,
         severity           = v_new_severity,
         status             = v_new_status,
         updated_at         = now()
   where id = p_rule_id;

  perform public._emit_activity(
    v_r.context_actor_id, v_caller,
    'rule.updated', 'rule', p_rule_id,
    jsonb_build_object('diff_keys', to_jsonb(v_diff_keys))
  );

  return jsonb_build_object(
    'rule_id', p_rule_id,
    'rule', (select to_jsonb(r) from public.rules r where r.id = p_rule_id),
    'diff_keys', to_jsonb(v_diff_keys),
    'no_op', false
  );
end; $$;

revoke all on function public.update_rule(uuid, text, text, text, jsonb, jsonb, text, jsonb, integer, text) from public, anon;
grant execute on function public.update_rule(uuid, text, text, text, jsonb, jsonb, text, jsonb, integer, text) to authenticated, service_role;

comment on function public.update_rule(uuid, text, text, text, jsonb, jsonb, text, jsonb, integer, text) is
  'F.RULE.2: edit rule canónico. Permiso rules.manage. Sólo reglas no archivadas.';

-- Smoke F.RULE.2
create or replace function public._smoke_f_rule_2_update_rule()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx uuid;
  v_rule uuid;
  v_result jsonb;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José F.R.2', '+5210000400');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David F.R.2', '+5210000401');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Cena F.R.2', 'collective', 'friend_group'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_rule := (public.create_rule(
    p_context_actor_id => v_ctx::uuid,
    p_title            => 'Llegar tarde'::text,
    p_trigger_event_type => 'event.checked_in'::text,
    p_condition_tree   => '{"op":">","field":"minutes_late","value":15}'::jsonb,
    p_consequences     => '[{"type":"fine","amount":100,"currency":"MXN"}]'::jsonb,
    p_target_scope     => 'event_type'::text,
    p_target_filter    => '{}'::jsonb
  ))->>'rule_id';

  -- 1. Admin edita título + severity
  v_result := public.update_rule(v_rule::uuid, 'Llegar muy tarde', null, null, null, null, null, null, 3);
  if (v_result->>'no_op')::boolean then raise exception 'F.R.2 FAIL 1'; end if;
  if (v_result->'rule'->>'title') <> 'Llegar muy tarde' then raise exception 'F.R.2 FAIL 1b'; end if;
  if (v_result->'rule'->>'severity')::int <> 3 then raise exception 'F.R.2 FAIL 1c'; end if;

  -- 2. No-op cuando nada cambia
  v_result := public.update_rule(v_rule::uuid);
  if not (v_result->>'no_op')::boolean then raise exception 'F.R.2 FAIL 2'; end if;

  -- 3. severity fuera de rango → 22023
  begin
    perform public.update_rule(v_rule::uuid, null, null, null, null, null, null, null, 10);
    raise exception 'F.R.2 FAIL 3';
  exception when sqlstate '22023' then null; end;

  -- 4. status inválido → 22023
  begin
    perform public.update_rule(v_rule::uuid, null, null, null, null, null, null, null, null, 'borrado');
    raise exception 'F.R.2 FAIL 4';
  exception when sqlstate '22023' then null; end;

  -- 5. David (sin rules.manage) no puede editar
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  begin
    perform public.update_rule(v_rule::uuid, 'hackeado');
    raise exception 'F.R.2 FAIL 5';
  exception when sqlstate '42501' then null; end;

  -- 6. Admin pausa la regla
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_result := public.update_rule(v_rule::uuid, null, null, null, null, null, null, null, null, 'paused');
  if (v_result->'rule'->>'status') <> 'paused' then raise exception 'F.R.2 FAIL 6'; end if;

  -- 7. Tras archivar (UPDATE directo), editar falla
  update public.rules set archived_at = now() where id = v_rule::uuid;
  begin
    perform public.update_rule(v_rule::uuid, 'tarde');
    raise exception 'F.R.2 FAIL 7';
  exception when sqlstate '22023' then null; end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'F.RULE.2 update_rule: PASS (7/7)';
end; $$;

revoke all on function public._smoke_f_rule_2_update_rule() from public, anon, authenticated;

create or replace function public._smoke_mvp2_f_rule_2_update_rule()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_f_rule_2_update_rule(); end; $$;
revoke all on function public._smoke_mvp2_f_rule_2_update_rule() from public, anon, authenticated;

comment on function public._smoke_mvp2_f_rule_2_update_rule() is
  'Wrapper CI del smoke F.RULE.2 — update_rule.';

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'update_rule') then
    raise exception 'F.RULE.2 DoD: falta update_rule';
  end if;
  raise notice 'F.RULE.2 DoD: update_rule shipped';
end $$;
