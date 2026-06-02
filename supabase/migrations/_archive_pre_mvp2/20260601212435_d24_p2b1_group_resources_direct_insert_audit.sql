-- D.24 P2B-1 — Soft block + audit para detectar inserts directos en
-- group_resources que bypaseen los 3 RPCs autorizados:
--   create_group_resource (envelope canonical)
--   create_event           (D.24 P1 event-specific con host/RSVP)
--   create_resource        (legacy polimórfico con jsonb payload)
--
-- Diseño:
-- 1. Authorized RPCs ponen un session GUC `ruul.resource_create_intent`
--    al inicio (SET LOCAL → transaction-scoped).
-- 2. AFTER INSERT trigger logea CADA insert a una audit table con el
--    intent_marker observado. Si intent_marker IS NULL, era directo.
-- 3. NUNCA raise — soft block per founder firm "no enforcement ciego".
-- 4. Listo para P2B-2 que flippeará a enforcement una vez que la audit
--    table muestre 0 direct inserts inesperados por una ventana de uso.

-- ============================================================
-- AUDIT TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS public.group_resources_direct_insert_audit (
    id              bigserial PRIMARY KEY,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    resource_id     uuid NOT NULL,
    group_id        uuid,
    resource_type   text,
    created_by      uuid,
    intent_marker   text,
    notes           text
);

CREATE INDEX IF NOT EXISTS group_resources_direct_insert_audit_occurred_at_idx
    ON public.group_resources_direct_insert_audit (occurred_at DESC);

CREATE INDEX IF NOT EXISTS group_resources_direct_insert_audit_unauthorized_idx
    ON public.group_resources_direct_insert_audit (occurred_at DESC)
    WHERE intent_marker IS NULL;

-- RLS: tabla interna, sólo service_role bypasea. No policies = nadie
-- excepto service_role puede leer/escribir.
ALTER TABLE public.group_resources_direct_insert_audit ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- TRIGGER FUNCTION
-- ============================================================
CREATE OR REPLACE FUNCTION public._log_group_resources_direct_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_intent text := current_setting('ruul.resource_create_intent', true);
BEGIN
    INSERT INTO public.group_resources_direct_insert_audit
        (resource_id, group_id, resource_type, created_by, intent_marker)
    VALUES
        (NEW.id, NEW.group_id, NEW.resource_type, NEW.created_by,
         NULLIF(v_intent, ''));
    -- AFTER INSERT trigger — return ignored, but convention.
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_log_group_resources_direct_insert
    ON public.group_resources;

CREATE TRIGGER trg_log_group_resources_direct_insert
    AFTER INSERT ON public.group_resources
    FOR EACH ROW
    EXECUTE FUNCTION public._log_group_resources_direct_insert();

-- ============================================================
-- AUTHORIZED RPCs — set intent_marker via SET LOCAL
-- ============================================================

-- create_group_resource (10-arg, P2A current)
CREATE OR REPLACE FUNCTION public.create_group_resource(
    p_group_id uuid,
    p_resource_type text,
    p_name text,
    p_description text DEFAULT NULL::text,
    p_visibility text DEFAULT 'members'::text,
    p_ownership_kind text DEFAULT 'group'::text,
    p_owner_membership_id uuid DEFAULT NULL::uuid,
    p_custodian_membership_id uuid DEFAULT NULL::uuid,
    p_metadata jsonb DEFAULT '{}'::jsonb,
    p_client_id text DEFAULT NULL::text
)
RETURNS public.group_resources
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_existing public.group_resources%ROWTYPE;
    v_row      public.group_resources%ROWTYPE;
BEGIN
    PERFORM set_config('ruul.resource_create_intent', 'create_group_resource', true);

    PERFORM public.assert_permission(p_group_id, 'resources.create');

    -- Idempotency via client_id (added P2A).
    IF p_client_id IS NOT NULL THEN
        SELECT * INTO v_existing FROM public.group_resources
        WHERE group_id = p_group_id AND client_id = p_client_id LIMIT 1;
        IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF;
    END IF;

    -- Validate resource_type against whitelist (CHECK on column does this
    -- too; we keep the call shape simple).
    IF p_resource_type NOT IN (
        'event','fund','space','asset','document','other',
        'right','slot','vehicle','tool','inventory','real_estate',
        'intellectual_property','money','points','equity','time','seat'
    ) THEN
        RAISE EXCEPTION 'invalid resource_type: %', p_resource_type
            USING errcode = '22023';
    END IF;

    INSERT INTO public.group_resources (
        group_id, resource_type, name, description, status, visibility,
        ownership_kind, owner_membership_id, metadata, client_id, created_by
    ) VALUES (
        p_group_id, p_resource_type, btrim(p_name), p_description,
        'active', p_visibility, p_ownership_kind, p_owner_membership_id,
        COALESCE(p_metadata, '{}'::jsonb), p_client_id, auth.uid()
    )
    RETURNING * INTO v_row;

    PERFORM public.record_system_event(
        p_group_id, 'resource.created', 'resource', v_row.id,
        btrim(p_name),
        jsonb_build_object('resource_type', p_resource_type)
    );

    RETURN v_row;
END;
$function$;

-- create_event (D.24 P1 — augment existing function with intent_marker)
CREATE OR REPLACE FUNCTION public.create_event(
    p_group_id uuid,
    p_title text,
    p_description text DEFAULT NULL::text,
    p_event_type text DEFAULT 'social'::text,
    p_starts_at timestamp with time zone DEFAULT NULL::timestamptz,
    p_ends_at timestamp with time zone DEFAULT NULL::timestamptz,
    p_timezone text DEFAULT NULL::text,
    p_location_name text DEFAULT NULL::text,
    p_location_address text DEFAULT NULL::text,
    p_location_url text DEFAULT NULL::text,
    p_recurrence_rule text DEFAULT NULL::text,
    p_visibility text DEFAULT 'group'::text,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
    v_uid uuid := (select auth.uid());
    v_membership_id uuid;
    v_resource_id uuid;
    v_metadata jsonb; v_roster jsonb;
    v_v text := coalesce(p_visibility,'group');
    v_type text := coalesce(p_event_type,'social');
begin
    perform set_config('ruul.resource_create_intent', 'create_event', true);

    if v_uid is null then raise exception 'auth_required' using errcode='42501'; end if;
    if not public.is_group_member(p_group_id) then raise exception 'not_a_member' using errcode='42501'; end if;
    if not public.has_group_permission(p_group_id,'events.create') then
        raise exception 'missing_permission: events.create' using errcode='42501'; end if;
    if p_title is null or length(btrim(p_title))=0 then raise exception 'title_required' using errcode='22023'; end if;
    if p_starts_at is null then raise exception 'starts_at_required' using errcode='22023'; end if;
    if p_ends_at is not null and p_ends_at < p_starts_at then raise exception 'ends_before_starts' using errcode='22023'; end if;
    perform public._event_v3_validate_visibility(v_v);
    perform public._event_v3_validate_type(v_type);

    v_membership_id := public._event_caller_membership(p_group_id);
    v_roster := case
        when v_membership_id is null then '[]'::jsonb
        else jsonb_build_array(jsonb_build_object(
            'id', gen_random_uuid(), 'membership_id', v_membership_id,
            'role', 'host', 'added_at', now()))
    end;
    v_metadata := coalesce(p_metadata,'{}'::jsonb) || jsonb_build_object(
        'resource_kind','event','event_subtype', v_type,
        'event_visibility', v_v, 'event_roster', v_roster,
        'timezone', p_timezone, 'location_address', p_location_address,
        'location_url', p_location_url, 'recurrence_rule', p_recurrence_rule
    );

    insert into public.group_resources (
        group_id, resource_type, name, description, status, visibility,
        ownership_kind, metadata, created_by
    ) values (
        p_group_id, 'event', btrim(p_title), p_description, 'active',
        public._event_v3_to_canon_visibility(v_v), 'group', v_metadata, v_uid
    ) returning id into v_resource_id;

    insert into public.group_resource_events (
        resource_id, starts_at, ends_at, location, host_membership_id
    ) values (v_resource_id, p_starts_at, p_ends_at, p_location_name, v_membership_id);

    if v_membership_id is not null then
        insert into public.group_rsvp_actions (
            group_id, resource_id, membership_id, user_id, rsvp_status, note, source, acted_at
        ) values (p_group_id, v_resource_id, v_membership_id, v_uid,
                  public._event_ios_to_canon_rsvp('accepted'),
                  null, 'auto_host', now());
    end if;

    perform public.record_system_event(
        p_group_id, 'resource.created', 'resource', v_resource_id, btrim(p_title),
        jsonb_build_object('resource_kind','event','event_subtype', v_type,
            'starts_at', p_starts_at, 'event_visibility', v_v,
            'recurring', p_recurrence_rule is not null));
    return v_resource_id;
end$function$;

-- create_resource (polymorphic legacy) — augment with intent_marker.
CREATE OR REPLACE FUNCTION public.create_resource(
    p_group_id uuid,
    p_resource_type text,
    p_name text,
    p_subtype_payload jsonb DEFAULT '{}'::jsonb,
    p_visibility text DEFAULT 'members'::text,
    p_ownership_kind text DEFAULT 'group'::text,
    p_series_id uuid DEFAULT NULL::uuid,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare v_id uuid; v_payload jsonb;
begin
  perform set_config('ruul.resource_create_intent', 'create_resource', true);

  perform public.assert_permission(p_group_id, 'resources.create');
  v_payload := coalesce(p_subtype_payload, '{}'::jsonb);

  insert into public.group_resources (
    group_id, resource_type, name, visibility, ownership_kind, series_id, metadata, created_by
  ) values (
    p_group_id, p_resource_type, p_name, p_visibility, p_ownership_kind, p_series_id,
    coalesce(p_metadata, '{}'::jsonb), auth.uid()
  ) returning id into v_id;

  if p_resource_type = 'event' then
    insert into public.group_resource_events (
      resource_id, starts_at, ends_at, location, location_geo, capacity, host_membership_id, rsvp_deadline
    ) values (
      v_id,
      coalesce((v_payload->>'starts_at')::timestamptz, now() + interval '1 day'),
      nullif(v_payload->>'ends_at','')::timestamptz,
      v_payload->>'location',
      v_payload->'location_geo',
      nullif(v_payload->>'capacity','')::int,
      nullif(v_payload->>'host_membership_id','')::uuid,
      nullif(v_payload->>'rsvp_deadline','')::timestamptz
    );
  elsif p_resource_type = 'fund' then
    insert into public.group_resource_funds (resource_id, fund_kind, currency, is_shared_pool, is_in_kind, threshold_target)
    values (
      v_id,
      coalesce(v_payload->>'fund_kind', 'pool'),
      coalesce(v_payload->>'currency', 'MXN'),
      coalesce((v_payload->>'is_shared_pool')::boolean, false),
      coalesce((v_payload->>'is_in_kind')::boolean, false),
      nullif(v_payload->>'threshold_target','')::numeric
    );
  elsif p_resource_type = 'slot' then
    insert into public.group_resource_slots (resource_id, slot_starts_at, slot_ends_at, assigned_membership_id)
    values (
      v_id,
      coalesce((v_payload->>'slot_starts_at')::timestamptz, now()),
      nullif(v_payload->>'slot_ends_at','')::timestamptz,
      nullif(v_payload->>'assigned_membership_id','')::uuid
    );
  elsif p_resource_type = 'space' then
    insert into public.group_resource_spaces (resource_id, address, geo, capacity, rules)
    values (
      v_id, v_payload->>'address', v_payload->'geo',
      nullif(v_payload->>'capacity','')::int, v_payload->>'rules'
    );
  elsif p_resource_type = 'asset' then
    insert into public.group_resource_assets (
      resource_id, asset_kind, serial_number, current_value, current_value_unit, condition, custodian_membership_id
    ) values (
      v_id, v_payload->>'asset_kind', v_payload->>'serial_number',
      nullif(v_payload->>'current_value','')::numeric,
      v_payload->>'current_value_unit', v_payload->>'condition',
      nullif(v_payload->>'custodian_membership_id','')::uuid
    );
  elsif p_resource_type = 'right' then
    insert into public.group_resource_rights (
      resource_id, right_kind, holder_membership_id, expires_at, transferable, conditions
    ) values (
      v_id, v_payload->>'right_kind',
      nullif(v_payload->>'holder_membership_id','')::uuid,
      nullif(v_payload->>'expires_at','')::timestamptz,
      coalesce((v_payload->>'transferable')::boolean, false),
      v_payload->>'conditions'
    );
  end if;

  perform public.record_system_event(
    p_group_id, 'resource.created', 'resource', v_id,
    p_name, jsonb_build_object('resource_type', p_resource_type)
  );
  return v_id;
end;
$function$;
