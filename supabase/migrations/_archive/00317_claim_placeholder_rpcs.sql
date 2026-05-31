-- Mig 00317: accept_placeholder_claim + decline_placeholder_claim.
--
-- Two claim paths converge in accept_placeholder_claim:
--   - Camino A (magic link): caller passes p_claim_token (raw, from URL).
--   - Camino B (phone match): caller passes p_placeholder_uid; SQL verifies
--     auth.uid()'s phone matches profiles[placeholder].phone.
--
-- Both paths end in merge_placeholder_into_user(placeholder, auth.uid())
-- inside a pg_advisory_xact_lock so concurrent taps serialize.
--
-- decline_placeholder_claim stamps disputed_at on the profile, deactivates
-- membership, burns the invite, emits a member.merge_declined atom, and
-- enqueues a placeholder_disputed notification for the admin who created
-- the placeholder.
--
-- Source: Docs/superpowers/specs/2026-05-17-placeholder-members-design.md §11.4, §14

create or replace function public.accept_placeholder_claim(
  p_claim_token text default null,
  p_placeholder_uid uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_catalog, extensions
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_phone text;
  v_placeholder uuid;
  v_invite record;
  v_invite_id uuid;
  v_group_id uuid;
  v_target_member_id uuid;
begin
  if v_actor is null then raise exception 'accept_placeholder_claim: not authenticated'; end if;

  if p_claim_token is not null then
    select * into v_invite
    from public.invites
    where claim_token_hash = encode(digest(p_claim_token::bytea, 'sha256'), 'hex')
      and used_at is null
      and expires_at > now()
      and placeholder_user_id is not null
    for update;
    if v_invite.id is null then raise exception 'accept_placeholder_claim: invalid_or_expired_token'; end if;
    v_placeholder := v_invite.placeholder_user_id;
    v_group_id := v_invite.group_id;
    v_invite_id := v_invite.id;

  elsif p_placeholder_uid is not null then
    select phone into v_actor_phone from auth.users where id = v_actor;
    if v_actor_phone is null then
      raise exception 'accept_placeholder_claim: no_verified_phone_for_caller';
    end if;

    if not exists (
      select 1 from public.profiles
      where id = p_placeholder_uid
        and is_placeholder = true
        and claimed_at is null
        and phone = v_actor_phone
    ) then raise exception 'accept_placeholder_claim: phone_mismatch_or_not_placeholder'; end if;

    v_placeholder := p_placeholder_uid;

    select * into v_invite
    from public.invites
    where placeholder_user_id = v_placeholder
      and used_at is null
    order by created_at desc
    limit 1
    for update;
    if v_invite.id is not null then
      v_group_id := v_invite.group_id;
      v_invite_id := v_invite.id;
    else
      select group_id into v_group_id
      from public.group_members where user_id = v_placeholder
      order by joined_at asc limit 1;
      if v_group_id is null then
        raise exception 'accept_placeholder_claim: placeholder_has_no_group';
      end if;
    end if;

  else
    raise exception 'accept_placeholder_claim: token_or_uid_required';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_placeholder::text));

  perform public.merge_placeholder_into_user(v_placeholder, v_actor);

  if v_invite_id is not null then
    update public.invites
      set used_at = now(), used_by_user_id = v_actor
      where id = v_invite_id;
  end if;

  select id into v_target_member_id
  from public.group_members where group_id = v_group_id and user_id = v_actor;

  perform public.record_system_event(
    p_group_id    := v_group_id,
    p_event_type  := 'member.claimed',
    p_resource_id := null,
    p_member_id   := v_target_member_id,
    p_payload     := jsonb_build_object(
      'placeholder_user_id', v_placeholder,
      'canonical_user_id',   v_actor,
      'invite_id',           v_invite_id,
      'path',                case when p_claim_token is not null then 'magic_link' else 'phone_match' end
    )
  );

  return jsonb_build_object(
    'canonical_user_id', v_actor,
    'group_id',          v_group_id,
    'member_id',         v_target_member_id
  );
end$$;

revoke all on function public.accept_placeholder_claim(text, uuid) from public, anon;
grant execute on function public.accept_placeholder_claim(text, uuid) to authenticated;

create or replace function public.decline_placeholder_claim(
  p_claim_token text
) returns jsonb
language plpgsql security definer set search_path = public, pg_catalog, extensions
as $$
declare
  v_actor uuid := auth.uid();
  v_invite record;
  v_placeholder_member_id uuid;
  v_admin_member_id uuid;
begin
  if v_actor is null then raise exception 'decline_placeholder_claim: not_authenticated'; end if;
  if p_claim_token is null then raise exception 'decline_placeholder_claim: token_required'; end if;

  select * into v_invite
  from public.invites
  where claim_token_hash = encode(digest(p_claim_token::bytea, 'sha256'), 'hex')
    and used_at is null
    and expires_at > now()
    and placeholder_user_id is not null
  for update;
  if v_invite.id is null then raise exception 'decline_placeholder_claim: invalid_or_expired_token'; end if;

  update public.profiles
    set disputed_at = now(),
        disputed_by_user_id = v_actor
    where id = v_invite.placeholder_user_id;

  update public.group_members
    set active = false
    where user_id = v_invite.placeholder_user_id
      and group_id = v_invite.group_id
    returning id into v_placeholder_member_id;

  update public.invites
    set used_at = now(), used_by_user_id = v_actor
    where id = v_invite.id;

  perform public.record_system_event(
    p_group_id    := v_invite.group_id,
    p_event_type  := 'member.merge_declined',
    p_resource_id := null,
    p_member_id   := v_placeholder_member_id,
    p_payload     := jsonb_build_object(
      'placeholder_user_id', v_invite.placeholder_user_id,
      'declined_by_user_id', v_actor,
      'invite_id',           v_invite.id,
      'reason',              'declined_by_real_owner'
    )
  );

  -- Notify the admin via notifications_outbox (best-effort — schema lives
  -- under public.notifications_outbox(recipient_member_id, notification_type,
  -- payload, deep_link, ...)). We resolve admin's member_id from the
  -- invite.invited_by user_id.
  select id into v_admin_member_id
  from public.group_members
  where group_id = v_invite.group_id and user_id = v_invite.invited_by
  limit 1;

  if v_admin_member_id is not null then
    begin
      insert into public.notifications_outbox
        (group_id, recipient_member_id, notification_type, payload, deep_link, scheduled_for)
      values (
        v_invite.group_id,
        v_admin_member_id,
        'placeholder_disputed',
        jsonb_build_object(
          'placeholder_user_id', v_invite.placeholder_user_id,
          'group_id',            v_invite.group_id,
          'disputed_by',         v_actor
        ),
        null,
        now()
      );
    exception when others then
      raise notice 'decline_placeholder_claim: outbox enqueue skipped (%)', sqlerrm;
    end;
  end if;

  return jsonb_build_object(
    'declined',            true,
    'placeholder_user_id', v_invite.placeholder_user_id,
    'group_id',            v_invite.group_id
  );
end$$;

revoke all on function public.decline_placeholder_claim(text) from public, anon;
grant execute on function public.decline_placeholder_claim(text) to authenticated;
