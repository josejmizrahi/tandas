-- R.1-WIRE.3 — Legacy ownership dual-write a resource_rights
--
-- Audit PR #131 hallazgo central (área C): existen 3 write-paths de ownership
-- paralelos vivos y solo resource_rights.OWN es doctrina:
--   1. resources.ownership_kind / owner_membership_id  ← set_resource_ownership
--   2. resource_owners                                  ← add_resource_owner / end_resource_owner
--   3. resource_rights.OWN (universal)                  ← grant_right 9-arg
--
-- Decisión: Opción A (dual-write) — los RPCs legacy mantienen su contrato y permisos
-- actuales (iOS los llama hoy con has_group_permission gating) y ADEMÁS sincronizan
-- resource_rights.OWN internamente. La Opción B (delegar a grant_right) re-ejecutaría
-- la autorización actor-céntrica R.1-SEC.2 con semántica distinta a la group-céntrica
-- que estos RPCs garantizan a sus callers, rompiendo flujos existentes.
--
-- Resultado: legacy ya no es fuente separada — todo write legacy aterriza también
-- en la fuente formal. Idempotente.

-- ============================================================
-- 0. Helper interno: upsert de OWN right desde flujos legacy
-- ============================================================
CREATE OR REPLACE FUNCTION public._upsert_own_right_from_legacy(
  p_resource_id uuid,
  p_holder_actor_id uuid,
  p_percent numeric,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_id       uuid;
  v_sentinel uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  SELECT id INTO v_id
    FROM public.resource_rights
   WHERE resource_id = p_resource_id
     AND COALESCE(holder_actor_id, v_sentinel) = COALESCE(p_holder_actor_id, v_sentinel)
     AND right_kind = 'OWN'
   ORDER BY
     CASE WHEN revoked_at IS NULL AND expired_at IS NULL THEN 0 ELSE 1 END,
     granted_at DESC
   LIMIT 1;

  IF v_id IS NOT NULL THEN
    UPDATE public.resource_rights
       SET percent    = COALESCE(p_percent, percent),
           metadata   = metadata || COALESCE(p_metadata, '{}'::jsonb),
           revoked_at = NULL,
           expired_at = NULL,
           granted_at = now()
     WHERE id = v_id;
  ELSE
    INSERT INTO public.resource_rights (resource_id, holder_actor_id, right_kind, percent, metadata)
    VALUES (p_resource_id, p_holder_actor_id, 'OWN', p_percent, COALESCE(p_metadata, '{}'::jsonb))
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public._upsert_own_right_from_legacy(uuid, uuid, numeric, jsonb) IS
  'R.1-WIRE.3 helper interno: upsert/undelete de OWN right desde los write-paths legacy de ownership. No expuesto a clientes.';

REVOKE ALL ON FUNCTION public._upsert_own_right_from_legacy(uuid, uuid, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._upsert_own_right_from_legacy(uuid, uuid, numeric, jsonb) TO service_role;

-- ============================================================
-- 1. add_resource_owner — dual-write OWN right
-- ============================================================
CREATE OR REPLACE FUNCTION public.add_resource_owner(p_resource_id uuid, p_owner_kind text, p_membership_id uuid DEFAULT NULL::uuid, p_external_party_id uuid DEFAULT NULL::uuid, p_ownership_pct numeric DEFAULT NULL::numeric, p_ownership_role text DEFAULT 'owner'::text, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_source_decision_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
declare
    v_uid uuid := (select auth.uid());
    v_resource public.group_resources%ROWTYPE;
    v_id uuid;
    v_holder_actor uuid;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_resource from public.group_resources where id=p_resource_id;
    if v_resource.id is null then raise exception 'resource_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_resource.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(v_resource.group_id, 'resources.manage_ownership') then
        raise exception 'missing_permission: resources.manage_ownership' using errcode='42501';
    end if;
    if p_owner_kind not in ('group','member','external_party','other') then
        raise exception 'invalid_owner_kind: %', p_owner_kind using errcode='22023';
    end if;
    if p_ownership_role is not null and p_ownership_role not in
        ('owner','co_owner','custodian','manager','beneficiary','steward','other') then
        raise exception 'invalid_ownership_role: %', p_ownership_role using errcode='22023';
    end if;
    if p_owner_kind='member' and p_membership_id is null then
        raise exception 'membership_id_required_for_member_owner' using errcode='22023';
    end if;
    if p_owner_kind='external_party' and p_external_party_id is null then
        raise exception 'external_party_id_required' using errcode='22023';
    end if;

    insert into public.group_resource_owners (
        group_id, resource_id,
        membership_id, external_party_id,
        owner_kind, ownership_pct, ownership_role,
        starts_at, source_decision_id, metadata
    ) values (
        v_resource.group_id, p_resource_id,
        case when p_owner_kind='member' then p_membership_id else null end,
        case when p_owner_kind='external_party' then p_external_party_id else null end,
        p_owner_kind, p_ownership_pct, coalesce(p_ownership_role,'owner'),
        coalesce(p_starts_at, now()),
        p_source_decision_id, coalesce(p_metadata,'{}'::jsonb)
    ) returning id into v_id;

    -- Enforce pct total ≤ 100 (deferred check, raise to undo this insert)
    perform public._assert_resource_ownership_pct_total(p_resource_id);

    -- ── R.1-WIRE.3: dual-write a universal resource_rights ──
    -- member → person actor (user_id); group → group actor (groups.id = actors.id);
    -- external_party → holder NULL + metadata.external_party_id (convención R.0C.2a)
    v_holder_actor := case p_owner_kind
        when 'member' then (select gm.user_id from public.group_memberships gm where gm.id = p_membership_id)
        when 'group'  then v_resource.group_id
        else null
    end;
    if v_holder_actor is not null or p_owner_kind = 'external_party' then
        perform public._upsert_own_right_from_legacy(
            p_resource_id,
            v_holder_actor,
            p_ownership_pct,
            jsonb_strip_nulls(jsonb_build_object(
                'legacy_owner_id', v_id,
                'source', 'r1_wire_dual_write_add_resource_owner',
                'external_party_id', p_external_party_id,
                'ownership_role', coalesce(p_ownership_role, 'owner')
            ))
        );
    end if;
    -- ─────────────────────────────────────────────────────────

    perform public.record_system_event(
        v_resource.group_id, 'resource.owner_added', 'resource', p_resource_id, v_resource.name,
        jsonb_build_object(
            'owner_id', v_id, 'owner_kind', p_owner_kind,
            'membership_id', p_membership_id, 'external_party_id', p_external_party_id,
            'ownership_pct', p_ownership_pct, 'ownership_role', p_ownership_role,
            'source_decision_id', p_source_decision_id));

    return v_id;
end$$;

-- ============================================================
-- 2. end_resource_owner — dual-write revoke del OWN right
-- ============================================================
CREATE OR REPLACE FUNCTION public.end_resource_owner(p_owner_id uuid, p_reason text DEFAULT NULL::text, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
declare
    v_uid uuid := (select auth.uid());
    v_o public.group_resource_owners%ROWTYPE;
    v_resource public.group_resources%ROWTYPE;
    v_holder_actor uuid;
begin
    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    select * into v_o from public.group_resource_owners where id=p_owner_id for update;
    if v_o.id is null then raise exception 'owner_not_found' using errcode='42704'; end if;
    if not public.is_group_member(v_o.group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(v_o.group_id, 'resources.manage_ownership') then
        raise exception 'missing_permission: resources.manage_ownership' using errcode='42501';
    end if;
    if v_o.ends_at is not null then return; end if;  -- idempotent

    update public.group_resource_owners
       set ends_at = coalesce(p_ends_at, now()),
           metadata = metadata || jsonb_strip_nulls(jsonb_build_object('end_reason', p_reason))
     where id = p_owner_id;

    -- ── R.1-WIRE.3: dual-write — revocar el OWN right universal correspondiente ──
    v_holder_actor := case v_o.owner_kind
        when 'member' then (select gm.user_id from public.group_memberships gm where gm.id = v_o.membership_id)
        when 'group'  then v_o.group_id
        else null
    end;
    update public.resource_rights
       set revoked_at = now(),
           metadata = metadata || jsonb_build_object(
               'revoke_source', 'end_resource_owner',
               'legacy_owner_id', p_owner_id)
     where resource_id = v_o.resource_id
       and right_kind = 'OWN'
       and revoked_at is null
       and (
         metadata->>'legacy_owner_id' = p_owner_id::text
         or (v_holder_actor is not null and holder_actor_id = v_holder_actor)
         or (v_holder_actor is null and v_o.external_party_id is not null
             and metadata->>'external_party_id' = v_o.external_party_id::text)
       );
    -- ──────────────────────────────────────────────────────────

    select * into v_resource from public.group_resources where id = v_o.resource_id;
    perform public.record_system_event(
        v_o.group_id, 'resource.owner_removed', 'resource', v_o.resource_id, v_resource.name,
        jsonb_build_object('owner_id', p_owner_id, 'owner_kind', v_o.owner_kind,
            'membership_id', v_o.membership_id, 'external_party_id', v_o.external_party_id,
            'reason', p_reason));
end$$;

-- ============================================================
-- 3. set_resource_ownership — dual-write transfer semantics
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_resource_ownership(p_resource_id uuid, p_ownership_kind text, p_owner_membership_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_r public.group_resources%rowtype;
  v_new_owner_actor uuid;
begin
  select * into v_r from public.group_resources where id = p_resource_id for update;
  if v_r.id is null then raise exception 'resource not found'; end if;
  perform public.assert_permission(v_r.group_id, 'resources.transfer');

  update public.group_resources
     set ownership_kind = p_ownership_kind,
         owner_membership_id = p_owner_membership_id,
         ownership_metadata = coalesce(p_metadata, '{}'::jsonb)
   where id = p_resource_id;

  -- ── R.1-WIRE.3: dual-write — transferencia reflejada en resource_rights ──
  -- group → group actor; individual/shared/custodial con membership → person actor.
  v_new_owner_actor := case
      when p_ownership_kind = 'group' then v_r.group_id
      when p_owner_membership_id is not null
        then (select gm.user_id from public.group_memberships gm where gm.id = p_owner_membership_id)
      else null
  end;
  if v_new_owner_actor is not null then
    -- transferencia: revocar OWN activos de otros holders
    update public.resource_rights
       set revoked_at = now(),
           metadata = metadata || '{"revoke_source": "set_resource_ownership_transfer"}'::jsonb
     where resource_id = p_resource_id
       and right_kind = 'OWN'
       and revoked_at is null
       and holder_actor_id is distinct from v_new_owner_actor;
    -- OWN 100% al nuevo owner
    perform public._upsert_own_right_from_legacy(
        p_resource_id, v_new_owner_actor, 100,
        jsonb_build_object('source', 'r1_wire_dual_write_set_resource_ownership'));
  end if;
  -- ──────────────────────────────────────────────────────────

  perform public.record_system_event(
    v_r.group_id, 'resource.ownership_changed', 'resource', p_resource_id,
    'Propiedad transferida',
    jsonb_build_object('to_kind', p_ownership_kind, 'to_member', p_owner_membership_id)
  );
end;
$$;
