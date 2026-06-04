-- F.DECISION.5 — update_decision RPC + edit_decision action emission.
-- Founder doctrine 2026-06-04: "editar Decision (title/description/closes_at)".
--
-- Reglas:
-- - Permiso: autor de la decisión OR decisions.execute.
-- - Sólo decisiones en status 'open' (votación abierta).
-- - NULL = "no cambiar" (COALESCE).
-- - title no-vacío.
-- - closes_at, si llega, no puede ser en el pasado.
-- - Emite activity decision.updated con diff_keys.
-- - decision_available_actions añade edit_decision (autor o execute, solo 'open').

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. update_decision(...)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.update_decision(
  p_decision_id uuid,
  p_title text default null,
  p_description text default null,
  p_closes_at timestamptz default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $$
declare
  v_caller uuid := public.current_actor_id();
  v_d public.decisions%rowtype;
  v_is_author boolean;
  v_can_manage boolean;
  v_new_title text;
  v_new_description text;
  v_new_closes_at timestamptz;
  v_diff_keys text[] := array[]::text[];
begin
  if v_caller is null then raise exception 'unauthenticated' using errcode = '28000'; end if;

  select * into v_d from public.decisions where id = p_decision_id for update;
  if v_d.id is null then raise exception 'decision not found' using errcode = 'P0002'; end if;

  v_is_author  := v_d.created_by_actor_id = v_caller;
  v_can_manage := public.has_actor_authority(v_d.context_actor_id, v_caller, 'decisions.execute');
  if not (v_is_author or v_can_manage) then
    raise exception 'not authorized to edit decision' using errcode = '42501';
  end if;

  if v_d.status <> 'open' then
    raise exception 'cannot edit decision in status %', v_d.status using errcode = '22023';
  end if;

  v_new_title       := coalesce(nullif(btrim(p_title), ''), v_d.title);
  v_new_description := coalesce(p_description, v_d.description);
  v_new_closes_at   := coalesce(p_closes_at, v_d.closes_at);

  if v_new_closes_at is not null and v_new_closes_at < now() then
    raise exception 'closes_at must be in the future' using errcode = '22023';
  end if;

  if v_new_title       is distinct from v_d.title       then v_diff_keys := array_append(v_diff_keys, 'title'); end if;
  if v_new_description is distinct from v_d.description then v_diff_keys := array_append(v_diff_keys, 'description'); end if;
  if v_new_closes_at   is distinct from v_d.closes_at   then v_diff_keys := array_append(v_diff_keys, 'closes_at'); end if;

  if array_length(v_diff_keys, 1) is null then
    return jsonb_build_object(
      'decision_id', p_decision_id,
      'decision', to_jsonb(v_d),
      'diff_keys', '[]'::jsonb,
      'no_op', true
    );
  end if;

  update public.decisions
     set title       = v_new_title,
         description = v_new_description,
         closes_at   = v_new_closes_at
   where id = p_decision_id;

  perform public._emit_activity(
    v_d.context_actor_id, v_caller,
    'decision.updated', 'decision', p_decision_id,
    jsonb_build_object('diff_keys', to_jsonb(v_diff_keys))
  );

  return jsonb_build_object(
    'decision_id', p_decision_id,
    'decision', (select to_jsonb(d) from public.decisions d where d.id = p_decision_id),
    'diff_keys', to_jsonb(v_diff_keys),
    'no_op', false
  );
end; $$;

revoke all on function public.update_decision(uuid, text, text, timestamptz) from public, anon;
grant execute on function public.update_decision(uuid, text, text, timestamptz) to authenticated, service_role;

comment on function public.update_decision(uuid, text, text, timestamptz) is
  'F.DECISION.5: edit decision canónico. Autor o decisions.execute. Sólo open.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. decision_available_actions — añadir edit_decision (sólo si open)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.decision_available_actions(p_decision_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_d public.decisions%rowtype;
  v_can_vote boolean;
  v_can_manage boolean;
  v_is_author boolean;
  v_already_voted boolean;
  v_actions jsonb := '[]'::jsonb;
begin
  select * into v_d from public.decisions where id = p_decision_id;
  if v_d.id is null then return '[]'::jsonb; end if;

  v_can_vote := public.has_actor_authority(v_d.context_actor_id, p_actor_id, 'decisions.vote');
  v_can_manage := public.has_actor_authority(v_d.context_actor_id, p_actor_id, 'decisions.execute');
  v_is_author := v_d.created_by_actor_id = p_actor_id;
  v_already_voted := exists (select 1 from public.decision_votes
                              where decision_id = p_decision_id and voter_actor_id = p_actor_id);

  if v_d.status = 'open' then
    if not v_already_voted then
      v_actions := v_actions || public._aa('vote', 'Votar', 'decisions',
        v_can_vote, case when v_can_vote then 'La decisión está abierta y puedes votar'
                         else 'No tienes permiso para votar en este contexto' end);
    else
      v_actions := v_actions || public._aa('change_vote', 'Cambiar voto', 'decisions',
        v_can_vote, case when v_can_vote then 'Ya votaste; puedes cambiar tu voto'
                         else 'No tienes permiso para votar en este contexto' end);
    end if;
    v_actions := v_actions || public._aa('close_decision', 'Cerrar votación', 'decisions',
      v_can_manage, case when v_can_manage then 'Puedes cerrar la votación'
                         else 'Requiere permiso decisions.execute' end);
    v_actions := v_actions || public._aa('cancel_decision', 'Cancelar decisión', 'decisions',
      v_can_manage, case when v_can_manage then 'Puedes cancelar la decisión'
                         else 'Requiere permiso decisions.execute' end);
    -- F.DECISION.5 — edit_decision: autor o decisions.execute, solo si open.
    v_actions := v_actions || public._aa('edit_decision', 'Editar decisión', 'decisions',
      v_is_author or v_can_manage,
      case when v_is_author then 'Eres el autor de la decisión'
           when v_can_manage then 'Tienes permiso para administrar decisiones'
           else 'Solo el autor o un administrador pueden editar la decisión' end);
  elsif v_d.status in ('approved', 'rejected') then
    v_actions := v_actions || public._aa('execute_decision', 'Ejecutar resultado', 'decisions',
      v_can_manage, case when v_can_manage then 'La decisión está cerrada y lista para ejecutar'
                         else 'Requiere permiso decisions.execute' end);
  end if;

  return v_actions;
end; $$;

revoke all on function public.decision_available_actions(uuid, uuid) from public, anon;
grant execute on function public.decision_available_actions(uuid, uuid) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Smoke F.DECISION.5
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._smoke_f_decision_5_update_decision()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_david uuid; a_david uuid;
  v_ctx uuid;
  v_decision uuid;
  v_result jsonb;
  v_aa jsonb;
  v_future timestamptz := now() + interval '7 days';
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('José F.DEC.5', '+5210000200');
  select auth_id, actor_id into u_david, a_david from public._r2_make_person('David F.DEC.5', '+5210000201');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('Trust F.DEC.5', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx::uuid, a_david);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  perform public.accept_invitation(v_ctx::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_decision := (public.create_decision(
                   p_context_actor_id => v_ctx::uuid,
                   p_decision_type    => 'generic'::text,
                   p_title            => 'Subir cuota'::text,
                   p_description      => 'Propongo subir la cuota mensual.'::text,
                   p_closes_at        => v_future,
                   p_template_key     => null::text))->>'decision_id';

  -- 1. Autor edita título + descripción
  v_result := public.update_decision(v_decision::uuid, 'Subir cuota mensual', 'A 1500');
  if (v_result->>'no_op')::boolean then raise exception 'F.DEC.5 FAIL 1: no_op cuando había cambios'; end if;
  if (v_result->'decision'->>'title') <> 'Subir cuota mensual' then
    raise exception 'F.DEC.5 FAIL 1: título no actualizó';
  end if;

  -- 2. No-op cuando nada cambia
  v_result := public.update_decision(v_decision::uuid);
  if not (v_result->>'no_op')::boolean then raise exception 'F.DEC.5 FAIL 2: esperaba no_op=true'; end if;

  -- 3. closes_at en el pasado → 22023
  begin
    perform public.update_decision(v_decision::uuid, null, null, now() - interval '1 hour');
    raise exception 'F.DEC.5 FAIL 3: aceptó closes_at en el pasado';
  exception when sqlstate '22023' then null;
  end;

  -- 4. David (no autor, no admin) no puede editar
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_david::text)::text, true);
  begin
    perform public.update_decision(v_decision::uuid, 'hackeado');
    raise exception 'F.DEC.5 FAIL 4: david pudo editar sin permisos';
  exception when sqlstate '42501' then null;
  end;

  -- 5. edit_decision aparece enabled para el autor
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_aa := public.decision_available_actions(v_decision::uuid, a_jose);
  if not exists (select 1 from jsonb_array_elements(v_aa) e
                 where e->>'action_key' = 'edit_decision' and (e->>'enabled')::boolean) then
    raise exception 'F.DEC.5 FAIL 5: autor no tiene edit_decision enabled';
  end if;

  -- 6. edit_decision aparece disabled para david
  v_aa := public.decision_available_actions(v_decision::uuid, a_david);
  if not exists (select 1 from jsonb_array_elements(v_aa) e
                 where e->>'action_key' = 'edit_decision' and not (e->>'enabled')::boolean) then
    raise exception 'F.DEC.5 FAIL 6: edit_decision para david debería estar disabled (intent-first)';
  end if;

  -- 7. Tras cerrar, edit_decision desaparece
  perform public.close_decision(v_decision::uuid);
  v_aa := public.decision_available_actions(v_decision::uuid, a_jose);
  if exists (select 1 from jsonb_array_elements(v_aa) e where e->>'action_key' = 'edit_decision') then
    raise exception 'F.DEC.5 FAIL 7: edit_decision aparece en decisión cerrada';
  end if;

  -- 8. Editar una decisión cerrada → 22023
  begin
    perform public.update_decision(v_decision::uuid, 'tarde');
    raise exception 'F.DEC.5 FAIL 8: aceptó editar decisión cerrada';
  exception when sqlstate '22023' then null;
  end;

  perform set_config('request.jwt.claims', null, true);
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_jose, a_david], array[u_jose, u_david]);

  raise notice 'F.DECISION.5 update_decision: PASS (8/8)';
end; $$;

revoke all on function public._smoke_f_decision_5_update_decision() from public, anon, authenticated;

create or replace function public._smoke_mvp2_f_decision_5_update_decision()
returns void language plpgsql security definer set search_path = public
as $$ begin perform public._smoke_f_decision_5_update_decision(); end; $$;
revoke all on function public._smoke_mvp2_f_decision_5_update_decision() from public, anon, authenticated;

comment on function public._smoke_mvp2_f_decision_5_update_decision() is
  'Wrapper CI del smoke F.DECISION.5 — update_decision + edit_decision action.';

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'update_decision') then
    raise exception 'F.DECISION.5 DoD: falta update_decision';
  end if;
  raise notice 'F.DECISION.5 DoD: update_decision + edit_decision action emission';
end $$;
