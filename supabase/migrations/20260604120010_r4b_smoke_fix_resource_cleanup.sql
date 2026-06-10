
create or replace function public._smoke_r4b_decision_templates()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_auth_a uuid := gen_random_uuid();
  v_person uuid;
  v_familia uuid;
  v_template_count int;
  v_decision_id uuid;
  v_decision_id_2 uuid;
  v_decision_id_3 uuid;
  v_decision_id_4 uuid;
  v_decision_id_5 uuid;
  v_decision_id_6 uuid;
  v_resource_id uuid;
  v_resource_id_2 uuid;
  v_rule_id uuid;
  v_other_actor uuid;
  v_auth_b uuid := gen_random_uuid();
  v_result jsonb;
  v_caught boolean;
  v_right_count int;
  v_archived_at timestamptz;
  v_rule_status text;
  v_persisted_voting_model text;
  v_persisted_template_key text;
begin
  v_person := public._create_person_actor_for_auth_user(
    v_auth_a, '_smoke_r4b founder', '+520000000942', null
  );
  v_other_actor := public._create_person_actor_for_auth_user(
    v_auth_b, '_smoke_r4b grantee', '+520000000943', null
  );

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_auth_a::text)::text, true);

  v_familia := (
    public.create_context('_smoke_r4b Familia','collective','family')
      ->>'context_actor_id'
  )::uuid;

  -- C1
  select count(*) into v_template_count from public.decision_templates_catalog;
  if v_template_count <> 12 then
    raise exception 'r4b C1: expected 12 templates, found %', v_template_count;
  end if;
  if not exists (select 1 from public.decision_templates_catalog
                 where template_key = 'generic' and execution_kind = 'noop') then
    raise exception 'r4b C1b: generic template missing or wrong execution_kind';
  end if;
  if not exists (select 1 from public.decision_templates_catalog
                 where template_key = 'archive_resource' and execution_kind = 'archive_resource') then
    raise exception 'r4b C1c: archive_resource template missing';
  end if;
  if not exists (select 1 from public.decision_templates_catalog
                 where template_key = 'resolve_reservation_conflict' and default_voting_model = 'single_choice') then
    raise exception 'r4b C1d: resolve_reservation_conflict default voting_model not single_choice';
  end if;

  -- C2
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='decisions' and column_name='template_key'
  ) then
    raise exception 'r4b C2a: decisions.template_key missing';
  end if;
  if not exists (
    select 1 from pg_indexes
    where schemaname='public' and indexname='idx_decisions_template'
  ) then
    raise exception 'r4b C2b: idx_decisions_template missing';
  end if;

  -- C3
  v_result := public.create_decision(
    p_context_actor_id => v_familia,
    p_decision_type    => 'generic',
    p_title            => 'R4B C3 — generic via template',
    p_template_key     => 'generic'
  );
  v_decision_id := (v_result->>'decision_id')::uuid;
  select template_key, voting_model into v_persisted_template_key, v_persisted_voting_model
    from public.decisions where id = v_decision_id;
  if v_persisted_template_key is distinct from 'generic' then
    raise exception 'r4b C3a: template_key not persisted (got %)', v_persisted_template_key;
  end if;
  if v_persisted_voting_model is distinct from 'yes_no_abstain' then
    raise exception 'r4b C3b: voting_model not inherited from template (got %)', v_persisted_voting_model;
  end if;

  -- C4
  v_caught := false;
  begin
    perform public.create_decision(
      p_context_actor_id => v_familia,
      p_decision_type    => 'generic',
      p_title            => 'R4B C4 — unknown template',
      p_template_key     => 'nonexistent_template_xyz'
    );
  exception when sqlstate 'P0002' then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'r4b C4: unknown template_key did not raise P0002';
  end if;

  -- C5
  update public.decisions set status = 'approved', decided_at = now()
    where id = v_decision_id;
  v_result := public.execute_decision(v_decision_id);
  if (v_result->>'status') <> 'executed' then
    raise exception 'r4b C5a: generic execute status not executed (got %)', v_result->>'status';
  end if;
  if not (v_result->'effects' @> '[{"type":"noop"}]'::jsonb) then
    raise exception 'r4b C5b: generic effects missing noop (got %)', v_result->'effects';
  end if;

  -- C6
  v_resource_id := (public.create_resource(
    p_context_actor_id => v_familia,
    p_resource_type    => 'digital_asset',
    p_display_name     => '_smoke_r4b Recurso'
  )->>'resource_id')::uuid;

  v_result := public.create_decision(
    p_context_actor_id => v_familia,
    p_decision_type    => 'governance',
    p_title            => 'R4B C6 — archive resource',
    p_payload          => jsonb_build_object('resource_id', v_resource_id),
    p_template_key     => 'archive_resource'
  );
  v_decision_id_2 := (v_result->>'decision_id')::uuid;
  update public.decisions set status = 'approved', decided_at = now()
    where id = v_decision_id_2;
  v_result := public.execute_decision(v_decision_id_2);

  select archived_at into v_archived_at from public.resources where id = v_resource_id;
  if v_archived_at is null then
    raise exception 'r4b C6a: resource.archived_at not set after execute';
  end if;
  if not (v_result->'effects' @> jsonb_build_array(jsonb_build_object('type','resource_archived','resource_id',v_resource_id))) then
    raise exception 'r4b C6b: archive_resource effects unexpected (got %)', v_result->'effects';
  end if;

  -- C7
  insert into public.rules
    (id, context_actor_id, created_by_actor_id, rule_type, status, title,
     trigger_event_type, condition_tree, consequences, severity)
  values
    (gen_random_uuid(), v_familia, v_person, 'norm', 'active',
     '_smoke_r4b rule to archive', 'event.created', '{}'::jsonb, '[]'::jsonb, 1)
  returning id into v_rule_id;

  v_result := public.create_decision(
    p_context_actor_id => v_familia,
    p_decision_type    => 'governance',
    p_title            => 'R4B C7 — archive rule',
    p_payload          => jsonb_build_object('rule_id', v_rule_id),
    p_template_key     => 'archive_rule'
  );
  v_decision_id_3 := (v_result->>'decision_id')::uuid;
  update public.decisions set status = 'approved', decided_at = now()
    where id = v_decision_id_3;
  perform public.execute_decision(v_decision_id_3);

  select status into v_rule_status from public.rules where id = v_rule_id;
  if v_rule_status <> 'archived' then
    raise exception 'r4b C7: rule.status not archived (got %)', v_rule_status;
  end if;

  -- C8
  v_resource_id_2 := (public.create_resource(
    p_context_actor_id => v_familia,
    p_resource_type    => 'digital_asset',
    p_display_name     => '_smoke_r4b Recurso Grant'
  )->>'resource_id')::uuid;

  v_result := public.create_decision(
    p_context_actor_id => v_familia,
    p_decision_type    => 'resources',
    p_title            => 'R4B C8 — grant right',
    p_payload          => jsonb_build_object(
      'resource_id', v_resource_id_2,
      'holder_actor_id', v_other_actor,
      'right_kind', 'USE',
      'scope', 'reads-and-rsvp'),
    p_template_key     => 'grant_resource_right'
  );
  v_decision_id_4 := (v_result->>'decision_id')::uuid;
  update public.decisions set status = 'approved', decided_at = now()
    where id = v_decision_id_4;
  v_result := public.execute_decision(v_decision_id_4);

  select count(*) into v_right_count
    from public.resource_rights
   where resource_id = v_resource_id_2
     and holder_actor_id = v_other_actor
     and right_kind = 'USE'
     and source_decision_id = v_decision_id_4
     and revoked_at is null;
  if v_right_count <> 1 then
    raise exception 'r4b C8: expected 1 active right granted by decision, got %', v_right_count;
  end if;

  -- C9
  v_result := public.create_decision(
    p_context_actor_id => v_familia,
    p_decision_type    => 'governance',
    p_title            => 'R4B C9 — unimplemented',
    p_payload          => jsonb_build_object('member_actor_id', v_other_actor),
    p_template_key     => 'admit_member'
  );
  v_decision_id_5 := (v_result->>'decision_id')::uuid;
  update public.decisions set status = 'approved', decided_at = now()
    where id = v_decision_id_5;
  v_caught := false;
  begin
    perform public.execute_decision(v_decision_id_5);
  exception when sqlstate '0A000' then
    v_caught := true;
  end;
  if not v_caught then
    raise exception 'r4b C9: unimplemented execution_kind did not raise feature_not_supported';
  end if;
  delete from public.decisions where id = v_decision_id_5;

  -- C10
  v_result := public.create_decision(
    p_context_actor_id => v_familia,
    p_decision_type    => 'generic',
    p_title            => 'R4B C10 — legacy path'
  );
  v_decision_id_6 := (v_result->>'decision_id')::uuid;
  update public.decisions set status = 'approved', decided_at = now()
    where id = v_decision_id_6;
  v_result := public.execute_decision(v_decision_id_6);
  if (v_result->>'status') <> 'executed' then
    raise exception 'r4b C10: legacy execute (no template_key) did not succeed';
  end if;
  if v_result->'effects' <> '[]'::jsonb then
    raise exception 'r4b C10b: legacy execute unexpected effects %', v_result->'effects';
  end if;

  -- C11
  v_result := public.execute_decision(v_decision_id_6);
  if not coalesce((v_result->>'already_executed')::boolean, false) then
    raise exception 'r4b C11: re-execute did not return already_executed=true (got %)', v_result;
  end if;

  -- Cleanup. activity_events stays (FK ON DELETE SET NULL).
  perform set_config('request.jwt.claims', null, true);

  delete from public.resource_rights where resource_id in (v_resource_id, v_resource_id_2);
  delete from public.rules where id = v_rule_id;
  delete from public.resources where id in (v_resource_id, v_resource_id_2);
  delete from public.decision_votes
   where decision_id in (v_decision_id, v_decision_id_2, v_decision_id_3,
                         v_decision_id_4, v_decision_id_6);
  delete from public.decisions
   where id in (v_decision_id, v_decision_id_2, v_decision_id_3, v_decision_id_4, v_decision_id_6);
  delete from public.role_assignments where context_actor_id = v_familia;
  delete from public.role_permissions rp using public.roles r
    where r.id = rp.role_id and r.context_actor_id = v_familia;
  delete from public.roles where context_actor_id = v_familia;
  delete from public.actor_memberships where context_actor_id = v_familia;
  delete from public.actors where id = v_familia;
  delete from public.person_profiles where actor_id in (v_person, v_other_actor);
  delete from public.actors where id in (v_person, v_other_actor);
  delete from auth.users where id in (v_auth_a, v_auth_b);

  raise notice '_smoke_r4b_decision_templates passed (11 casos)';
end;
$$;

revoke all on function public._smoke_r4b_decision_templates() from anon;
grant execute on function public._smoke_r4b_decision_templates() to service_role;
