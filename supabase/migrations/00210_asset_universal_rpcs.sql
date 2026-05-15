-- Mig 00200 — Asset universal RPCs (canonical asset spec).
--
-- The 9 SECURITY DEFINER RPCs that materialize the canonical asset
-- atoms onto `system_events`. Each is gated by `is_group_member`
-- (any member can call) — finer-grained governance lives in `rules`
-- + `group_policies` per Constitution Article 7. The platform's job
-- here is only to validate + emit the atom; downstream rules decide
-- what (warning, fine, vote, …) happens next.
--
-- Each RPC follows the same shape as the existing `create_asset` /
-- `record_settlement` / `start_vote` calls:
--   1. auth.uid() check.
--   2. resolve target asset row + group_id.
--   3. is_group_member(group_id, caller) gate.
--   4. light input validation.
--   5. record_system_event(...).
--   6. (some RPCs) update `resources.metadata` for the projection
--      shortcut (e.g. `metadata.custodian_id`) so the iOS list view
--      can render without joining `system_events` on every row.
--
-- Reads (current_custodian_view, asset_valuation_view,
-- maintenance_status_view, asset_usage_history_view) live in mig
-- 00201 — projections derive from the atoms emitted here.

-- =============================================================================
-- 1. assign_custody — designate the physical/operational custodian
-- =============================================================================

create or replace function public.assign_custody(
  p_asset_id    uuid,
  p_custodian_member_id uuid,
  p_notes       text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id      uuid := auth.uid();
  v_group_id       uuid;
  v_resource_type  text;
  v_target_active  boolean;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type into v_group_id, v_resource_type
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  select active into v_target_active
  from public.group_members
  where id = p_custodian_member_id and group_id = v_group_id;
  if v_target_active is null then
    raise exception 'custodian not in this group' using errcode = '02000';
  end if;
  if not v_target_active then
    raise exception 'custodian member is not active' using errcode = '22023';
  end if;

  update public.resources
  set metadata = metadata || jsonb_build_object(
    'custodian_id',          p_custodian_member_id::text,
    'custody_assigned_at',   now()
  )
  where id = p_asset_id;

  perform public.record_system_event(
    v_group_id,
    'custodyAssigned',
    p_asset_id,
    p_custodian_member_id,
    jsonb_build_object(
      'assigned_by', v_caller_id,
      'notes',       p_notes
    )
  );
end;
$$;

revoke execute on function public.assign_custody(uuid, uuid, text) from public, anon;
grant  execute on function public.assign_custody(uuid, uuid, text) to authenticated;

comment on function public.assign_custody(uuid, uuid, text) is
  'Asset spec §10 — designate the physical/operational custodian (separate from ownership). Any group member may call. Emits custodyAssigned + writes metadata.custodian_id for projection shortcut.';

-- =============================================================================
-- 2. release_custody — return the asset to "in group custody"
-- =============================================================================

create or replace function public.release_custody(
  p_asset_id uuid,
  p_notes    text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id          uuid := auth.uid();
  v_group_id           uuid;
  v_resource_type      text;
  v_metadata           jsonb;
  v_prev_custodian_id  uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type, metadata
    into v_group_id, v_resource_type, v_metadata
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  v_prev_custodian_id := nullif(v_metadata->>'custodian_id', '')::uuid;

  update public.resources
  set metadata = (metadata - 'custodian_id' - 'custody_assigned_at')
    || jsonb_build_object('custody_released_at', now())
  where id = p_asset_id;

  perform public.record_system_event(
    v_group_id,
    'custodyReleased',
    p_asset_id,
    v_prev_custodian_id,
    jsonb_build_object(
      'released_by', v_caller_id,
      'notes',       p_notes
    )
  );
end;
$$;

revoke execute on function public.release_custody(uuid, text) from public, anon;
grant  execute on function public.release_custody(uuid, text) to authenticated;

comment on function public.release_custody(uuid, text) is
  'Asset spec §10 — release current custody. Asset returns to group-level custody (no custodian_id). Emits custodyReleased.';

-- =============================================================================
-- 3. log_maintenance — record service / repair / inspection
-- =============================================================================

create or replace function public.log_maintenance(
  p_asset_id   uuid,
  p_kind       text,
  p_notes      text  default null,
  p_cost_cents bigint default null,
  p_currency   text  default 'MXN'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_event_id      uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type into v_group_id, v_resource_type
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_kind is null or length(trim(p_kind)) = 0 then
    raise exception 'maintenance kind required' using errcode = '22023';
  end if;
  if p_cost_cents is not null and p_cost_cents < 0 then
    raise exception 'cost must be non-negative' using errcode = '22023';
  end if;

  v_event_id := public.record_system_event(
    v_group_id,
    'maintenanceLogged',
    p_asset_id,
    null,
    jsonb_build_object(
      'logged_by',   v_caller_id,
      'kind',        trim(p_kind),
      'notes',       p_notes,
      'cost_cents',  p_cost_cents,
      'currency',    coalesce(p_currency, 'MXN'),
      'status',      'open'
    )
  );

  return v_event_id;
end;
$$;

revoke execute on function public.log_maintenance(uuid, text, text, bigint, text) from public, anon;
grant  execute on function public.log_maintenance(uuid, text, text, bigint, text) to authenticated;

comment on function public.log_maintenance(uuid, text, text, bigint, text) is
  'Asset spec §12 — log a maintenance task (service, inspection, repair). Status defaults to open; complete_maintenance flips it to done. Returns the system_event id.';

-- =============================================================================
-- 4. complete_maintenance — mark a logged task as done
-- =============================================================================

create or replace function public.complete_maintenance(
  p_maintenance_event_id uuid,
  p_notes                text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_asset_id      uuid;
  v_event_type    text;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_id, event_type
    into v_group_id, v_asset_id, v_event_type
  from public.system_events
  where id = p_maintenance_event_id;
  if v_group_id is null then
    raise exception 'maintenance event not found' using errcode = '02000';
  end if;
  if v_event_type <> 'maintenanceLogged' then
    raise exception 'event % is not a maintenance log', v_event_type using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  perform public.record_system_event(
    v_group_id,
    'maintenanceCompleted',
    v_asset_id,
    null,
    jsonb_build_object(
      'completed_by',         v_caller_id,
      'notes',                p_notes,
      'maintenance_event_id', p_maintenance_event_id
    )
  );
end;
$$;

revoke execute on function public.complete_maintenance(uuid, text) from public, anon;
grant  execute on function public.complete_maintenance(uuid, text) to authenticated;

comment on function public.complete_maintenance(uuid, text) is
  'Asset spec §12 — mark a previously-logged maintenance task as done. Append-only: logs a separate maintenanceCompleted atom referencing the original via payload.maintenance_event_id; the projection joins them.';

-- =============================================================================
-- 5. report_damage — record damage incident
-- =============================================================================

create or replace function public.report_damage(
  p_asset_id  uuid,
  p_severity  text,
  p_notes     text default null,
  p_estimated_cost_cents bigint default null,
  p_currency  text default 'MXN'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_event_id      uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type into v_group_id, v_resource_type
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_severity not in ('minor', 'moderate', 'major', 'total') then
    raise exception 'severity must be minor|moderate|major|total' using errcode = '22023';
  end if;
  if p_estimated_cost_cents is not null and p_estimated_cost_cents < 0 then
    raise exception 'estimated cost must be non-negative' using errcode = '22023';
  end if;

  v_event_id := public.record_system_event(
    v_group_id,
    'damageReported',
    p_asset_id,
    null,
    jsonb_build_object(
      'reported_by',           v_caller_id,
      'severity',              p_severity,
      'notes',                 p_notes,
      'estimated_cost_cents',  p_estimated_cost_cents,
      'currency',              coalesce(p_currency, 'MXN')
    )
  );

  return v_event_id;
end;
$$;

revoke execute on function public.report_damage(uuid, text, text, bigint, text) from public, anon;
grant  execute on function public.report_damage(uuid, text, text, bigint, text) to authenticated;

comment on function public.report_damage(uuid, text, text, bigint, text) is
  'Asset spec §13 — report damage on an asset. Severity is bounded; notes free-form. Rule engine can react via damageReported trigger (e.g. open vote when severity=major).';

-- =============================================================================
-- 6. record_valuation — append a valuation point
-- =============================================================================

create or replace function public.record_valuation(
  p_asset_id   uuid,
  p_value_cents bigint,
  p_currency   text default 'MXN',
  p_source     text default null,
  p_notes      text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_event_id      uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type into v_group_id, v_resource_type
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_value_cents is null or p_value_cents < 0 then
    raise exception 'value must be non-negative' using errcode = '22023';
  end if;

  v_event_id := public.record_system_event(
    v_group_id,
    'valuationRecorded',
    p_asset_id,
    null,
    jsonb_build_object(
      'recorded_by', v_caller_id,
      'value_cents', p_value_cents,
      'currency',    coalesce(p_currency, 'MXN'),
      'source',      p_source,
      'notes',       p_notes
    )
  );

  return v_event_id;
end;
$$;

revoke execute on function public.record_valuation(uuid, bigint, text, text, text) from public, anon;
grant  execute on function public.record_valuation(uuid, bigint, text, text, text) to authenticated;

comment on function public.record_valuation(uuid, bigint, text, text, text) is
  'Asset spec §16 — append a valuation point. Value is immutable per atom; latest projection lives in asset_valuation_view (mig 00201).';

-- =============================================================================
-- 7. transfer_asset — move ownership to another member or to the group
-- =============================================================================

create or replace function public.transfer_asset(
  p_asset_id          uuid,
  p_to_member_id      uuid,
  p_notes             text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_metadata      jsonb;
  v_prev_owner_id uuid;
  v_target_active boolean;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type, metadata
    into v_group_id, v_resource_type, v_metadata
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  v_prev_owner_id := nullif(v_metadata->>'owner_id', '')::uuid;

  if p_to_member_id is not null then
    select active into v_target_active
    from public.group_members
    where id = p_to_member_id and group_id = v_group_id;
    if v_target_active is null then
      raise exception 'target member not in this group' using errcode = '02000';
    end if;
    if not v_target_active then
      raise exception 'target member not active' using errcode = '22023';
    end if;
  end if;

  if p_to_member_id is not null then
    update public.resources
    set metadata = metadata || jsonb_build_object(
      'owner_id',           p_to_member_id::text,
      'ownership_changed_at', now()
    )
    where id = p_asset_id;
  else
    -- transfer to group (no individual owner)
    update public.resources
    set metadata = (metadata - 'owner_id')
      || jsonb_build_object('ownership_changed_at', now())
    where id = p_asset_id;
  end if;

  perform public.record_system_event(
    v_group_id,
    'assetTransferred',
    p_asset_id,
    p_to_member_id,
    jsonb_build_object(
      'transferred_by', v_caller_id,
      'from_member_id', v_prev_owner_id,
      'to_member_id',   p_to_member_id,
      'notes',          p_notes
    )
  );
end;
$$;

revoke execute on function public.transfer_asset(uuid, uuid, text) from public, anon;
grant  execute on function public.transfer_asset(uuid, uuid, text) to authenticated;

comment on function public.transfer_asset(uuid, uuid, text) is
  'Asset spec §10/§24 — transfer ownership to another member or back to the group (p_to_member_id=null). Updates metadata.owner_id + emits assetTransferred. Custody is independent and not affected.';

-- =============================================================================
-- 8. check_out_asset — physical/digital handover for temporary use
-- =============================================================================

create or replace function public.check_out_asset(
  p_asset_id           uuid,
  p_to_member_id       uuid default null,
  p_expected_return_at timestamptz default null,
  p_notes              text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id        uuid := auth.uid();
  v_group_id         uuid;
  v_resource_type    text;
  v_caller_member_id uuid;
  v_target_member_id uuid;
  v_target_active    boolean;
  v_event_id         uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type into v_group_id, v_resource_type
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  -- Resolve target: defaults to the caller's own member id (self check-out).
  if p_to_member_id is null then
    select id into v_caller_member_id
    from public.group_members
    where group_id = v_group_id and user_id = v_caller_id and active;
    if v_caller_member_id is null then
      raise exception 'caller not active member' using errcode = '42501';
    end if;
    v_target_member_id := v_caller_member_id;
  else
    select active into v_target_active
    from public.group_members
    where id = p_to_member_id and group_id = v_group_id;
    if v_target_active is null then
      raise exception 'target member not in this group' using errcode = '02000';
    end if;
    if not v_target_active then
      raise exception 'target member not active' using errcode = '22023';
    end if;
    v_target_member_id := p_to_member_id;
  end if;

  -- Mark asset as checked-out for the projection shortcut. Uses a
  -- separate metadata key from custody so a checkout doesn't clobber
  -- the long-lived custodian relationship.
  update public.resources
  set metadata = metadata || jsonb_build_object(
    'checked_out_to',     v_target_member_id::text,
    'checked_out_at',     now(),
    'expected_return_at', p_expected_return_at
  )
  where id = p_asset_id;

  v_event_id := public.record_system_event(
    v_group_id,
    'assetCheckedOut',
    p_asset_id,
    v_target_member_id,
    jsonb_build_object(
      'checked_out_by',     v_caller_id,
      'expected_return_at', p_expected_return_at,
      'notes',              p_notes
    )
  );

  return v_event_id;
end;
$$;

revoke execute on function public.check_out_asset(uuid, uuid, timestamptz, text) from public, anon;
grant  execute on function public.check_out_asset(uuid, uuid, timestamptz, text) to authenticated;

comment on function public.check_out_asset(uuid, uuid, timestamptz, text) is
  'Asset spec §13 — record a checkout (physical handover for temporary use). Distinct from custody: a custodian can still loan the asset out without giving up custody. Defaults to self-checkout.';

-- =============================================================================
-- 9. check_in_asset — return the asset
-- =============================================================================

create or replace function public.check_in_asset(
  p_asset_id        uuid,
  p_condition_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id          uuid := auth.uid();
  v_group_id           uuid;
  v_resource_type      text;
  v_metadata           jsonb;
  v_prev_holder_id     uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type, metadata
    into v_group_id, v_resource_type, v_metadata
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  v_prev_holder_id := nullif(v_metadata->>'checked_out_to', '')::uuid;

  update public.resources
  set metadata = metadata
    - 'checked_out_to'
    - 'checked_out_at'
    - 'expected_return_at'
  where id = p_asset_id;

  perform public.record_system_event(
    v_group_id,
    'assetCheckedIn',
    p_asset_id,
    v_prev_holder_id,
    jsonb_build_object(
      'checked_in_by',   v_caller_id,
      'condition_notes', p_condition_notes
    )
  );
end;
$$;

revoke execute on function public.check_in_asset(uuid, text) from public, anon;
grant  execute on function public.check_in_asset(uuid, text) to authenticated;

comment on function public.check_in_asset(uuid, text) is
  'Asset spec §13 — record an asset return (closes the prior checkout). Anyone in the group can mark it returned; condition_notes free-form for damage signalling.';

-- =============================================================================
-- 10. record_asset_usage — append a usage atom
-- =============================================================================

create or replace function public.record_asset_usage(
  p_asset_id uuid,
  p_notes    text default null,
  p_units    int  default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id     uuid := auth.uid();
  v_group_id      uuid;
  v_resource_type text;
  v_event_id      uuid;
begin
  if v_caller_id is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select group_id, resource_type into v_group_id, v_resource_type
  from public.resources
  where id = p_asset_id;
  if v_group_id is null then
    raise exception 'asset not found' using errcode = '02000';
  end if;
  if v_resource_type <> 'asset' then
    raise exception 'resource is not an asset' using errcode = '22023';
  end if;

  if not public.is_group_member(v_group_id, v_caller_id) then
    raise exception 'not a member of this group' using errcode = '42501';
  end if;

  if p_units is not null and p_units < 0 then
    raise exception 'units must be non-negative' using errcode = '22023';
  end if;

  v_event_id := public.record_system_event(
    v_group_id,
    'assetUsed',
    p_asset_id,
    null,
    jsonb_build_object(
      'used_by', v_caller_id,
      'notes',   p_notes,
      'units',   p_units
    )
  );

  return v_event_id;
end;
$$;

revoke execute on function public.record_asset_usage(uuid, text, int) from public, anon;
grant  execute on function public.record_asset_usage(uuid, text, int) to authenticated;

comment on function public.record_asset_usage(uuid, text, int) is
  'Asset spec §13 — append an asset.used atom. Optional units count for inventory-style assets (e.g. fabric rolls, storage bytes). Feeds asset_usage_history_view.';
