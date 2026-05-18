-- Mig 00232: polymorphic resource_links — Fase 2 Slice 1
--
-- Doctrine source: Plans/Active/ResourceLinks.md
--
-- Brings the existing event-only `link_resource_to_event` /
-- `unlink_resource_from_event` RPCs to the full 8-relation V1 catalog
-- (uses, funds, governs, located_in, scheduled_in, reserves,
-- grants_access_to, owns) with polymorphic (from_type, to_type, kind)
-- validation via a lookup table.
--
-- Architecture per founder directive:
--   * Catálogo cerrado, no free text.
--   * `resource_links` table stays as projection/cache.
--   * `resourceLinked` / `resourceUnlinked` atoms in system_events are
--     truth (already in `is_known_system_event_type` whitelist from
--     mig 00198 — confirmed by inspection).
--   * Admin can unlink (no governance gate yet).
--   * `owns` ontology: connects resources (e.g., fund→asset);
--     human ownership lives via `right.holder_member_id`. The two
--     never collide.
--
-- Backward compat: `link_resource_to_event` / `unlink_resource_from_event`
-- become thin wrappers over the new polymorphic RPCs. iOS callers
-- migrate at their own pace.

BEGIN;

-- ============================================================
-- 1. Catalog table: which (from_type, to_type, kind) tuples are valid.
-- ============================================================
-- A table beats a CASE/WHEN function because: future relations land as
-- INSERT rows (not function rewrites); the catalog is queryable from
-- the client to drive picker UX; constraints are pg-enforced.

CREATE TABLE IF NOT EXISTS public.resource_link_kinds (
  kind       text NOT NULL,
  from_type  text NOT NULL,
  to_type    text NOT NULL,
  PRIMARY KEY (kind, from_type, to_type)
);

COMMENT ON TABLE public.resource_link_kinds IS
  'Canonical catalog of valid (kind, from_type, to_type) tuples for resource_links. V1 = 8 relations per Plans/Active/ResourceLinks.md §3. New rows require doc edit + migration.';

-- Seed V1 catalog. Order in the values lists is alphabetical to make
-- diff-review easy; semantics are unordered.

-- `uses`: event/fund consumes another resource to operate.
INSERT INTO public.resource_link_kinds (kind, from_type, to_type) VALUES
  ('uses', 'event', 'asset'),
  ('uses', 'event', 'fund'),
  ('uses', 'event', 'slot'),
  ('uses', 'event', 'space'),
  ('uses', 'fund',  'asset'),
  ('uses', 'fund',  'space')
ON CONFLICT DO NOTHING;

-- `funds`: a fund financially backs the target.
INSERT INTO public.resource_link_kinds (kind, from_type, to_type) VALUES
  ('funds', 'fund', 'asset'),
  ('funds', 'fund', 'event'),
  ('funds', 'fund', 'space')
ON CONFLICT DO NOTHING;

-- `governs`: a right controls the target's lifecycle / behavior.
INSERT INTO public.resource_link_kinds (kind, from_type, to_type) VALUES
  ('governs', 'right', 'asset'),
  ('governs', 'right', 'fund'),
  ('governs', 'right', 'slot'),
  ('governs', 'right', 'space')
ON CONFLICT DO NOTHING;

-- `located_in`: physical location of an asset/slot is a space.
INSERT INTO public.resource_link_kinds (kind, from_type, to_type) VALUES
  ('located_in', 'asset', 'space'),
  ('located_in', 'slot',  'space')
ON CONFLICT DO NOTHING;

-- `scheduled_in`: an event/slot occurs in a space.
INSERT INTO public.resource_link_kinds (kind, from_type, to_type) VALUES
  ('scheduled_in', 'event', 'space'),
  ('scheduled_in', 'slot',  'space')
ON CONFLICT DO NOTHING;

-- `reserves`: a slot reserves capacity on a space or asset.
INSERT INTO public.resource_link_kinds (kind, from_type, to_type) VALUES
  ('reserves', 'slot', 'asset'),
  ('reserves', 'slot', 'space')
ON CONFLICT DO NOTHING;

-- `grants_access_to`: a right opens access to the target.
INSERT INTO public.resource_link_kinds (kind, from_type, to_type) VALUES
  ('grants_access_to', 'right', 'asset'),
  ('grants_access_to', 'right', 'slot'),
  ('grants_access_to', 'right', 'space')
ON CONFLICT DO NOTHING;

-- `owns`: a fund holds title to a resource purchased through it.
-- NOTE per founder directive: `owns` connects resources, NOT humans.
-- Human ownership = `right.holder_member_id` (different ontology).
INSERT INTO public.resource_link_kinds (kind, from_type, to_type) VALUES
  ('owns', 'fund', 'asset'),
  ('owns', 'fund', 'space')
ON CONFLICT DO NOTHING;

-- Drop the legacy `link_kind = 'uses'` check that predated the
-- catalog. If it stayed, the new tuples below would all 23514.
ALTER TABLE public.resource_links
  DROP CONSTRAINT IF EXISTS resource_links_kind_known_chk;

-- Lock down the kinds column to the V1 set so a typo can't ship to prod.
-- Future additions: ADD VALUE in this CHECK + an INSERT into the table.
ALTER TABLE public.resource_links
  DROP CONSTRAINT IF EXISTS resource_links_link_kind_v1_check;

ALTER TABLE public.resource_links
  ADD CONSTRAINT resource_links_link_kind_v1_check
  CHECK (link_kind IN (
    'uses', 'funds', 'governs', 'located_in', 'scheduled_in',
    'reserves', 'grants_access_to', 'owns'
  ));

-- Expose the catalog to the client (read-only).
ALTER TABLE public.resource_link_kinds ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS resource_link_kinds_read_all ON public.resource_link_kinds;
CREATE POLICY resource_link_kinds_read_all
  ON public.resource_link_kinds
  FOR SELECT
  USING (true);

GRANT SELECT ON public.resource_link_kinds TO authenticated, anon;

-- ============================================================
-- 2. Validation helper
-- ============================================================

CREATE OR REPLACE FUNCTION public.is_valid_resource_link(
  p_from_type text,
  p_to_type   text,
  p_kind      text
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.resource_link_kinds
     WHERE kind = p_kind
       AND from_type = p_from_type
       AND to_type   = p_to_type
  );
$$;

-- ============================================================
-- 3. Polymorphic link_resources RPC
-- ============================================================

CREATE OR REPLACE FUNCTION public.link_resources(
  p_from_resource_id uuid,
  p_to_resource_id   uuid,
  p_link_kind        text DEFAULT 'uses'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  v_uid          uuid := auth.uid();
  v_from_group   uuid;
  v_from_type    text;
  v_to_group     uuid;
  v_to_type      text;
  v_existing_id  uuid;
  v_link_id      uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_from_resource_id = p_to_resource_id then
    raise exception 'cannot link a resource to itself' using errcode = '22023';
  end if;

  select group_id, resource_type
    into v_from_group, v_from_type
    from public.resources
   where id = p_from_resource_id
     and archived_at is null;

  if v_from_group is null then
    raise exception 'from resource not found or archived' using errcode = '42704';
  end if;

  select group_id, resource_type
    into v_to_group, v_to_type
    from public.resources
   where id = p_to_resource_id
     and archived_at is null;

  if v_to_group is null then
    raise exception 'to resource not found or archived' using errcode = '42704';
  end if;

  if v_to_group <> v_from_group then
    raise exception 'cross-group links are not allowed' using errcode = '22023';
  end if;

  if not public.is_valid_resource_link(v_from_type, v_to_type, p_link_kind) then
    raise exception 'invalid link tuple: (% -> % :%) not in catalog',
      v_from_type, v_to_type, p_link_kind
      using errcode = '22023';
  end if;

  if not public.is_group_member(v_from_group, v_uid) then
    raise exception 'caller is not a member of this group'
      using errcode = '42501';
  end if;

  -- Already linked? Return the existing row id (idempotent).
  select id into v_existing_id
    from public.resource_links
   where from_resource_id = p_from_resource_id
     and to_resource_id   = p_to_resource_id
     and link_kind        = p_link_kind
     and unlinked_at      is null;

  if v_existing_id is not null then
    return v_existing_id;
  end if;

  insert into public.resource_links (
    group_id, from_resource_id, to_resource_id, link_kind, linked_by
  ) values (
    v_from_group, p_from_resource_id, p_to_resource_id, p_link_kind, v_uid
  )
  returning id into v_link_id;

  perform public.record_system_event(
    v_from_group,
    'resourceLinked',
    p_from_resource_id,
    null,
    jsonb_build_object(
      'link_id',            v_link_id,
      'link_kind',          p_link_kind,
      'from_resource_id',   p_from_resource_id,
      'from_resource_type', v_from_type,
      'to_resource_id',     p_to_resource_id,
      'to_resource_type',   v_to_type,
      'linked_by',          v_uid
    )
  );

  return v_link_id;
end;
$$;

REVOKE EXECUTE ON FUNCTION public.link_resources(uuid, uuid, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.link_resources(uuid, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.link_resources(uuid, uuid, text) IS
  'Polymorphic resource graph linker. Validates (from_type, to_type, link_kind) against resource_link_kinds catalog. Emits resourceLinked atom. Idempotent — returns existing link id when already active. Admin can unlink; see unlink_resources.';

-- ============================================================
-- 4. Polymorphic unlink_resources RPC (by tuple, not by link_id)
-- ============================================================

CREATE OR REPLACE FUNCTION public.unlink_resources(
  p_from_resource_id uuid,
  p_to_resource_id   uuid,
  p_link_kind        text DEFAULT 'uses'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  v_uid        uuid := auth.uid();
  v_link_id    uuid;
  v_group_id   uuid;
  v_from_type  text;
  v_to_type    text;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select id, group_id
    into v_link_id, v_group_id
    from public.resource_links
   where from_resource_id = p_from_resource_id
     and to_resource_id   = p_to_resource_id
     and link_kind        = p_link_kind
     and unlinked_at      is null
   for update;

  if v_link_id is null then
    -- Already absent — no-op (idempotent).
    return;
  end if;

  if not public.is_group_admin(v_group_id, v_uid) then
    raise exception 'only admins can unlink resources' using errcode = '42501';
  end if;

  select resource_type into v_from_type from public.resources where id = p_from_resource_id;
  select resource_type into v_to_type   from public.resources where id = p_to_resource_id;

  update public.resource_links
     set unlinked_at = now(),
         unlinked_by = v_uid
   where id = v_link_id;

  perform public.record_system_event(
    v_group_id,
    'resourceUnlinked',
    p_from_resource_id,
    null,
    jsonb_build_object(
      'link_id',            v_link_id,
      'link_kind',          p_link_kind,
      'from_resource_id',   p_from_resource_id,
      'from_resource_type', v_from_type,
      'to_resource_id',     p_to_resource_id,
      'to_resource_type',   v_to_type,
      'unlinked_by',        v_uid
    )
  );
end;
$$;

REVOKE EXECUTE ON FUNCTION public.unlink_resources(uuid, uuid, text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.unlink_resources(uuid, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.unlink_resources(uuid, uuid, text) IS
  'Polymorphic resource unlinker by tuple. Admin-only gate per founder directive (no resolve_governance hook yet — refinable). Idempotent — silent no-op when no active link matches. Emits resourceUnlinked atom on success.';

-- ============================================================
-- 5. Backward-compat shims for the event-only legacy RPCs
-- ============================================================
-- iOS callers gradually migrate to link_resources / unlink_resources.
-- Until then, the legacy entry points keep working — they now route
-- through the polymorphic functions so the catalog + atoms behave the
-- same way regardless of which RPC is used.

CREATE OR REPLACE FUNCTION public.link_resource_to_event(
  p_event_id    uuid,
  p_resource_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
begin
  return public.link_resources(p_event_id, p_resource_id, 'uses');
end;
$$;

COMMENT ON FUNCTION public.link_resource_to_event(uuid, uuid) IS
  'Legacy wrapper for the event-only link flow (pre-Fase 2). Delegates to link_resources(from, to, ''uses''). Kept for backward compat; new code uses link_resources directly.';

CREATE OR REPLACE FUNCTION public.unlink_resource_from_event(
  p_link_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  v_from_id uuid;
  v_to_id   uuid;
  v_kind    text;
  v_unlink  timestamptz;
begin
  select from_resource_id, to_resource_id, link_kind, unlinked_at
    into v_from_id, v_to_id, v_kind, v_unlink
    from public.resource_links
   where id = p_link_id;

  if v_from_id is null then
    raise exception 'link not found' using errcode = '42704';
  end if;

  if v_unlink is not null then
    return;
  end if;

  perform public.unlink_resources(v_from_id, v_to_id, v_kind);
end;
$$;

COMMENT ON FUNCTION public.unlink_resource_from_event(uuid) IS
  'Legacy by-id wrapper. Resolves the tuple from p_link_id and delegates to unlink_resources. New code uses unlink_resources(from, to, kind) directly.';

-- ============================================================
-- 6. Sanity surfaces in apply log
-- ============================================================
DO $$
declare
  v_catalog_count int;
  v_link_count    int;
begin
  select count(*) into v_catalog_count from public.resource_link_kinds;
  select count(*) into v_link_count    from public.resource_links;
  raise notice 'mig 00268: catalog has % tuples, resource_links has % rows',
    v_catalog_count, v_link_count;
end;
$$;

COMMIT;
