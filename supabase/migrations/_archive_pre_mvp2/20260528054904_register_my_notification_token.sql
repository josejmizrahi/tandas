create or replace function public.register_my_notification_token(
  p_token text,
  p_platform text default 'ios'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_id uuid;
  v_trimmed text := nullif(btrim(p_token), '');
  v_platform text := lower(coalesce(p_platform, 'ios'));
begin
  if v_user_id is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if v_trimmed is null then
    raise exception 'token_required' using errcode = '23502';
  end if;
  if v_platform not in ('ios', 'android', 'web') then
    raise exception 'invalid_platform' using errcode = '22023';
  end if;

  insert into public.notification_tokens (user_id, token, platform)
  values (v_user_id, v_trimmed, v_platform)
  on conflict (user_id, token) do update
    set platform = excluded.platform,
        updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.register_my_notification_token(text, text) from public;
grant execute on function public.register_my_notification_token(text, text) to authenticated;

comment on function public.register_my_notification_token(text, text) is
  'V3-A2 — upserts the caller''s APNs/FCM device token into notification_tokens (unique on user_id+token). Bumps updated_at on re-registration so the dispatcher has a last-seen signal. authenticated-only.';
