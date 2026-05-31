-- 20260527000000 — list_my_groups RPC + accept_invite state cleanup.
--
-- Two root-cause fixes that surfaced on device 2026-05-27:
--
-- BUG #1 — iOS GroupListView showed the same group multiple times.
-- Cause: SupabaseRuulRPCClient.listMyGroups() did
--   `from("group_memberships").select("..., groups(...)")`
--   .eq("status","active")
-- but RLS on group_memberships lets any active member see EVERY
-- membership of their group (is_group_member(group_id) OR
-- user_id = auth.uid()). With 3 members in "Bros", PostgREST returned
-- 3 rows of group_memberships, each embedding the same groups(...)
-- row, and the UI rendered "Bros" three times.
--
-- Doctrina fix: iOS no debe conocer joins sociales. Canonical RPC
-- `list_my_groups()` runs SECURITY DEFINER, filters by auth.uid() +
-- status='active' server-side, and ships a flat row per group
-- (membership_id, group_id, name, slug, category, purpose_summary).
-- iOS replaces the `from(...)` select with `rpc('list_my_groups')`.
--
-- BUG #2 — Jose en "Bros" tenía status='active' AND left_at NOT NULL.
-- Cause: accept_invite, cuando reactiva una membership existente
-- (v_existing_id no null), hace `set status='active', joined_at=...,
-- confirmed_at=now()` y se olvida de limpiar left_at / left_reason /
-- suspended_until / suspended_reason. Re-aceptar una invitación
-- después de irse deja la fila en estado contradictorio.
--
-- Fix: el UPDATE en la rama "reactivate existing" limpia los campos
-- de salida/suspensión. Backfill al final de la migración corrige
-- las filas inconsistentes que ya existen en dev.

-- ===========================================================================
-- 1. RPC: list_my_groups
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.list_my_groups()
RETURNS TABLE (
  membership_id    uuid,
  group_id         uuid,
  name             text,
  slug             text,
  category         text,
  purpose_summary  text,
  joined_at        timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_catalog'
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'must be authenticated' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (g.id)
    gm.id              AS membership_id,
    g.id               AS group_id,
    g.name             AS name,
    g.slug             AS slug,
    g.category         AS category,
    g.purpose_summary  AS purpose_summary,
    gm.joined_at       AS joined_at
  FROM public.group_memberships gm
  JOIN public.groups g ON g.id = gm.group_id
  WHERE gm.user_id = v_uid
    AND gm.status  = 'active'
  ORDER BY g.id, gm.joined_at DESC NULLS LAST;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.list_my_groups() FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.list_my_groups() TO authenticated;

COMMENT ON FUNCTION public.list_my_groups() IS
  'Foundation groups slice (mig 20260527000000): returns the caller''s active groups, one row per group. SECURITY DEFINER filter by auth.uid() + status=active; DISTINCT ON (group_id) defends against any future case where a user accidentally holds multiple active memberships in the same group.';

-- ===========================================================================
-- 2. Fix accept_invite: clear left_at / left_reason / suspended fields
--    when reactivating an existing membership.
-- ===========================================================================
-- Only the "reactivate existing membership" branch changes — the other
-- two branches (placeholder claim, fresh insert) already write a clean
-- row.

CREATE OR REPLACE FUNCTION public.accept_invite(p_code text)
RETURNS TABLE(group_id uuid, membership_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_invite       public.group_invites%rowtype;
  v_token_hash   text;
  v_membership   uuid;
  v_existing_id  uuid;
  v_default_role uuid;
  v_has_role     int;
begin
  if auth.uid() is null then raise exception 'must be authenticated'; end if;

  select * into v_invite from public.group_invites gi
   where gi.code = upper(p_code) and gi.status = 'pending'
   limit 1;
  if v_invite.id is null then raise exception 'invite not found or already used'; end if;
  if v_invite.expires_at is not null and v_invite.expires_at < now() then
    update public.group_invites gi set status = 'expired' where gi.id = v_invite.id;
    raise exception 'invite expired';
  end if;

  v_token_hash := encode(extensions.digest(upper(p_code) || v_invite.group_id::text, 'sha256'), 'hex');
  if v_token_hash <> v_invite.token_hash then
    raise exception 'invite token mismatch';
  end if;

  select gm.id into v_existing_id from public.group_memberships gm
   where gm.group_id = v_invite.group_id and gm.user_id = auth.uid();

  if v_existing_id is not null then
    -- Reactivation: clear ALL lifecycle remnants so the row reflects a
    -- clean active state. The previous version forgot left_at /
    -- left_reason / suspended_*, leaving rows like (status='active',
    -- left_at NOT NULL) after leave → re-accept.
    update public.group_memberships gm
       set status            = 'active',
           joined_at         = coalesce(gm.joined_at, now()),
           confirmed_at      = now(),
           left_at           = null,
           left_reason       = null,
           suspended_until   = null,
           suspended_reason  = null
     where gm.id = v_existing_id;
    v_membership := v_existing_id;
  elsif v_invite.placeholder_membership_id is not null then
    update public.group_memberships gm
       set user_id = auth.uid(), status = 'active',
           joined_at = now(), confirmed_at = now(), joined_via = 'placeholder_claim',
           left_at = null, left_reason = null,
           suspended_until = null, suspended_reason = null
     where gm.id = v_invite.placeholder_membership_id
     returning gm.id into v_membership;
  else
    insert into public.group_memberships (group_id, user_id, status, joined_at, joined_via)
    values (v_invite.group_id, auth.uid(), 'active', now(), 'invite_code')
    returning id into v_membership;
  end if;

  select count(*) into v_has_role
    from public.group_member_roles gmr
   where gmr.membership_id = v_membership;
  if v_has_role = 0 then
    select gr.id into v_default_role
      from public.group_roles gr
     where gr.group_id = v_invite.group_id and gr.is_default = true
     limit 1;
    if v_default_role is not null then
      insert into public.group_member_roles (membership_id, role_id, assigned_by)
      values (v_membership, v_default_role, auth.uid())
      on conflict do nothing;
    end if;
  end if;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  values (v_invite.group_id, v_membership, auth.uid(), 'joined', 'invite_accepted');

  update public.group_invites gi
     set status = 'accepted', accepted_at = now(), invited_user_id = auth.uid()
   where gi.id = v_invite.id;

  perform public.record_system_event(
    v_invite.group_id, 'member.joined', 'membership', v_membership,
    'Miembro aceptó la invitación', '{}'::jsonb
  );

  group_id := v_invite.group_id;
  membership_id := v_membership;
  return next;
  return;
end;
$$;

-- ===========================================================================
-- 3. Backfill: any row that ended up with status='active' but a
--    populated left_at/left_reason. These are the rows produced by the
--    pre-fix accept_invite. The state should be exactly one of:
--      (a) active + left_at NULL  → correct active row, clear left_reason
--      (b) left   + left_at SET   → correct departed row
--    We preserve the founder-visible intent: if status='active' the
--    user IS in the group right now, so left_at/left_reason are stale
--    artifacts and we clear them.
-- ===========================================================================

UPDATE public.group_memberships
   SET left_at = NULL,
       left_reason = NULL,
       suspended_until = NULL,
       suspended_reason = NULL
 WHERE status = 'active'
   AND (left_at IS NOT NULL OR left_reason IS NOT NULL
        OR suspended_until IS NOT NULL OR suspended_reason IS NOT NULL);
