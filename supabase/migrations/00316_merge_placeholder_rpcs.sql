-- Mig 00316: merge_placeholder_into_user + _merge_group_members.
--
-- Append-only contract:
--   - DOES reassign mutable projections: group_members, profiles,
--     notification_tokens, notification_preferences.
--   - DOES NOT touch atoms: system_events, ledger_entries (auto-inherit via
--     group_members.id reassignment), vote_casts (also member_id-based,
--     auto-inherits), user_actions (user_id-based but append-only — resolved
--     via identity_resolver view at query time).
--   - DOES NOT delete the placeholder's auth.users row — atoms (incl.
--     user_actions and identity_atoms) still reference its id. The row is
--     marked with raw_user_meta_data.merged_into = canonical_uid.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §12

create or replace function public._merge_group_members(
  p_placeholder uuid,
  p_target uuid
) returns void
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  r record;
begin
  for r in
    select gm_p.*
    from public.group_members gm_p
    where gm_p.user_id = p_placeholder
  loop
    if exists (
      select 1 from public.group_members
      where group_id = r.group_id and user_id = p_target
    ) then
      -- Conflict: target already a member. Merge metadata into target row,
      -- drop placeholder row. We preserve turn_order from placeholder
      -- (the admin assigned it consciously) only when target.turn_order
      -- is NULL.
      update public.group_members tgt
        set
          turn_order = coalesce(tgt.turn_order, r.turn_order),
          roles = coalesce(tgt.roles, '[]'::jsonb)
                  || coalesce(r.roles, '[]'::jsonb),
          active = tgt.active or r.active
        where tgt.group_id = r.group_id and tgt.user_id = p_target;

      delete from public.group_members
        where group_id = r.group_id and user_id = p_placeholder;
    else
      -- Simple reassign. The group_members.id stays the same — every atom
      -- and projection that points at member_id (system_events,
      -- ledger_entries, vote_casts, fines, etc.) is automatically the
      -- target's history now.
      update public.group_members
        set user_id = p_target
        where group_id = r.group_id and user_id = p_placeholder;
    end if;
  end loop;
end$$;

revoke all on function public._merge_group_members(uuid, uuid) from public, anon, authenticated;

create or replace function public.merge_placeholder_into_user(
  p_placeholder uuid,
  p_target uuid
) returns void
language plpgsql security definer set search_path = public, pg_catalog
as $$
declare
  v_meta jsonb;
begin
  if p_placeholder = p_target then return; end if;

  if not exists (
    select 1 from public.profiles
    where id = p_placeholder and is_placeholder = true and claimed_at is null
  ) then
    raise exception 'merge_placeholder_into_user: % is not an unclaimed placeholder', p_placeholder;
  end if;

  if exists (
    select 1 from auth.users
    where id = p_target and coalesce(is_anonymous, false) = true
  ) then
    raise exception 'merge_placeholder_into_user: target % is anonymous', p_target;
  end if;

  -- Stamp merged_into on placeholder auth.users so identity_resolver maps
  -- atoms that point at the placeholder uid (user_actions) to the canonical
  -- owner.
  select raw_user_meta_data into v_meta from auth.users where id = p_placeholder;
  update auth.users
    set raw_user_meta_data = coalesce(v_meta, '{}'::jsonb)
      || jsonb_build_object('merged_into', p_target::text)
    where id = p_placeholder;

  -- Reassign membership (preserves member_id history for all atoms that
  -- reference group_members.id).
  perform public._merge_group_members(p_placeholder, p_target);

  -- notification_tokens: avoid duplicate (user_id, token) by deleting
  -- placeholder rows whose tokens already exist for the target, then
  -- UPDATEing the rest.
  delete from public.notification_tokens
    where user_id = p_placeholder
      and exists (
        select 1 from public.notification_tokens t2
        where t2.user_id = p_target and t2.token = notification_tokens.token
      );
  update public.notification_tokens
    set user_id = p_target
    where user_id = p_placeholder;

  -- notification_preferences: target keeps its own; drop placeholder's row.
  delete from public.notification_preferences
    where user_id = p_placeholder;

  -- Delete placeholder profile row (canonical owner = target's profile,
  -- which already exists since target is a real user).
  delete from public.profiles where id = p_placeholder;

  -- Atoms (system_events, vote_casts, user_actions, ledger_entries,
  -- identity_atoms) intentionally untouched. identity_resolver view bridges
  -- the user_actions / vote_casts on-historical-uid case.
end$$;

revoke all on function public.merge_placeholder_into_user(uuid, uuid) from public, anon, authenticated;
grant execute on function public.merge_placeholder_into_user(uuid, uuid) to service_role;
