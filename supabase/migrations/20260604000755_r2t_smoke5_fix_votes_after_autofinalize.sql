-- Fix: votar 3 veces hace que la 3ra falle porque la decision ya está aprobada.
-- Patrón R.2S contract smoke: 2 votos + execute_decision explícito.
create or replace function public._smoke_r2t_decision_resolves_conflict()
returns void
language plpgsql security definer set search_path = public, auth
as $$
declare
  u_jose uuid; a_jose uuid;
  u_papa uuid; a_papa uuid;
  u_abu uuid;  a_abu uuid;
  v_ctx uuid;
  v_palco uuid;
  v_event uuid;
  v_starts timestamptz := now() + interval '50 days';
  v_ends   timestamptz := now() + interval '50 days' + interval '3 hours';
  v_resv1 uuid; v_resv2 uuid;
  v_conflict uuid;
  v_decision uuid;
  v_winner_opt text;
  v_status text;
begin
  select auth_id, actor_id into u_jose, a_jose from public._r2_make_person('R2T José rslv2', '+5210000241');
  select auth_id, actor_id into u_papa, a_papa from public._r2_make_person('R2T Papá rslv2', '+5210000242');
  select auth_id, actor_id into u_abu,  a_abu  from public._r2_make_person('R2T Abuelo rslv2', '+5210000243');

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_ctx := (public.create_context('R2T Mizrahi Resolve2', 'collective', 'family'))->>'context_actor_id';
  perform public.invite_member(v_ctx, a_papa);
  perform public.invite_member(v_ctx, a_abu);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  perform public.accept_invitation(v_ctx);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);

  v_palco := (public.create_resource(v_ctx, 'house', 'Palco Azteca R2T Resolve2'))->>'resource_id';
  perform public.grant_right(v_palco, v_ctx, 'MANAGE');
  perform public.grant_right(v_palco, a_papa, 'USE');
  perform public.grant_right(v_palco, a_abu, 'USE');

  v_event := (public.create_calendar_event(
    p_context_actor_id := v_ctx,
    p_title := 'México vs Brasil (resolve2)',
    p_event_type := 'community_event',
    p_starts_at := v_starts,
    p_ends_at := v_ends,
    p_invite_all_members := false))->>'event_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  v_resv1 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_papa,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_abu::text)::text, true);
  v_resv2 := (public.request_resource_reservation(
    p_resource_id := v_palco, p_context_actor_id := v_ctx,
    p_starts_at := v_starts, p_ends_at := v_ends,
    p_reserved_for_actor_id := a_abu,
    p_source_event_id := v_event::uuid))->>'reservation_id';

  select id into v_conflict from public.reservation_conflicts
    where resource_id = v_palco and resolution_status = 'open'
      and (reservation_a_id = v_resv2::uuid or reservation_b_id = v_resv2::uuid)
    limit 1;
  if v_conflict is null then
    raise exception 'R2T smoke 5: no se produjo conflict para resolver';
  end if;

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  v_decision := (public.resolve_reservation_conflict(v_conflict, 'requires_decision'))->>'decision_id';

  select case when (payload->'option_reservations'->>'res_a')::uuid = v_resv1::uuid then 'res_a' else 'res_b' end
    into v_winner_opt
    from public.decisions where id = v_decision;

  -- Patrón R.2S contract: 2 votos sólo, después execute_decision (sin votar 3ro
  -- porque tras 2 votos a favor la decision auto-finaliza y la 3ra raise 22023).
  perform public.vote_decision(v_decision, 'approve', v_winner_opt);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_papa::text)::text, true);
  perform public.vote_decision(v_decision, 'approve', v_winner_opt);

  perform set_config('request.jwt.claims', jsonb_build_object('sub', u_jose::text)::text, true);
  perform public.execute_decision(v_decision);

  select resolution_status into v_status
    from public.reservation_conflicts where id = v_conflict;
  if v_status <> 'resolved' then
    raise exception 'R2T smoke 5: conflict no quedó resolved, got %', v_status;
  end if;

  raise notice 'R2T smoke 5 OK: decision % resolvió conflict %', v_decision, v_conflict;
end; $$;

revoke all on function public._smoke_r2t_decision_resolves_conflict() from public, anon;
grant execute on function public._smoke_r2t_decision_resolves_conflict() to service_role;