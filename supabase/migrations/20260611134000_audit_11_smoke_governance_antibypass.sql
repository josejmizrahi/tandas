-- ============================================================================
-- AUDIT.11 — Smoke: anti-bypass de governance en remove_member (2026-06-11)
-- ============================================================================
-- Fase 2 ítem 6 del SupabaseCleanupMigrationPlan. La doctrina R.7 dice: con la
-- policy activa, NINGÚN camino directo ejecuta la acción peligrosa — ni
-- siquiera el override admin. Este smoke vuelve invariante de CI que:
--   1. Con `member_ban_requires_vote = true`, remove_member directo falla
--      (governance_required) y la membresía queda intacta.
--   2. `p_force => true` (override del guard de obligaciones R.9.E) TAMPOCO
--      bypassa el gate de governance.
--   3. Al desactivar la policy, el camino directo vuelve a operar (el gate es
--      de la policy, no un bloqueo permanente).
-- El happy path completo request→decision→vote→execute ya lo cubren los
-- smokes R.5/R.7; aquí solo se blinda el anti-bypass.
-- ============================================================================

create or replace function public._smoke_mvp2_audit_governance_antibypass()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  u_a uuid; a_a uuid;
  u_b uuid; a_b uuid;
  v_ctx uuid; v_code text;
  v_caught boolean;
  v_result jsonb;
begin
  select auth_id, actor_id into u_a, a_a from public._r2_make_person('Admin AntiBypass', '+5210000993');
  select auth_id, actor_id into u_b, a_b from public._r2_make_person('Member AntiBypass', '+5210000994');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  v_ctx := (public.create_context('Governance AntiBypass Smoke', 'collective', 'friend_group'))->>'context_actor_id';
  v_code := (public.create_invite(v_ctx::uuid))->>'code';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text)::text, true);
  perform public.join_by_invite_code(v_code);

  -- Activar la policy
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text)::text, true);
  perform public.create_governance_policy(v_ctx::uuid, 'member_ban_requires_vote', 'true'::jsonb);

  -- 1. Camino directo bloqueado
  v_caught := false;
  begin
    perform public.remove_member(v_ctx::uuid, a_b);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'antibypass 1: remove_member directo operó con la policy activa';
  end if;
  if not exists (select 1 from public.actor_memberships
                  where context_actor_id = v_ctx and member_actor_id = a_b
                    and membership_status = 'active') then
    raise exception 'antibypass 1b: la membresía no quedó intacta tras el bloqueo';
  end if;

  -- 2. p_force tampoco bypassa governance
  v_caught := false;
  begin
    perform public.remove_member(v_ctx::uuid, a_b, p_force := true);
  exception when others then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'antibypass 2: p_force => true bypasseó el gate de governance';
  end if;
  if not exists (select 1 from public.actor_memberships
                  where context_actor_id = v_ctx and member_actor_id = a_b
                    and membership_status = 'active') then
    raise exception 'antibypass 2b: la membresía no quedó intacta tras el bloqueo con p_force';
  end if;

  -- 3. Policy desactivada → el camino directo vuelve a operar
  perform public.update_governance_policy(v_ctx::uuid, 'member_ban_requires_vote', 'false'::jsonb);
  v_result := public.remove_member(v_ctx::uuid, a_b, p_reason := 'smoke antibypass');
  if coalesce((v_result->>'removed')::boolean, false) is not true then
    raise exception 'antibypass 3: remove_member no operó con la policy desactivada';
  end if;
  if not exists (select 1 from public.actor_memberships
                  where context_actor_id = v_ctx and member_actor_id = a_b
                    and membership_status = 'removed') then
    raise exception 'antibypass 3b: la membresía no quedó removed';
  end if;

  -- Cleanup
  perform public._r2_cleanup_context(v_ctx::uuid, array[a_a, a_b], array[u_a, u_b]);
  raise notice '_smoke_mvp2_audit_governance_antibypass: green';
end;
$$;

revoke all on function public._smoke_mvp2_audit_governance_antibypass() from public, anon, authenticated;

comment on function public._smoke_mvp2_audit_governance_antibypass() is
  'AUDIT.11: con member_ban_requires_vote activa, remove_member directo y con p_force quedan bloqueados (membresía intacta); desactivada, el camino directo vuelve a operar.';

-- Ejecución inline: el smoke debe nacer verde
do $$ begin perform public._smoke_mvp2_audit_governance_antibypass(); end $$;
