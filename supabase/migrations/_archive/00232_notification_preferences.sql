-- Mig 00232: notification_preferences — per-user per-type opt-out.
create table public.notification_preferences (
    user_id           uuid not null references auth.users(id) on delete cascade,
    notification_type text not null,
    enabled           boolean not null default true,
    updated_at        timestamptz not null default now(),
    primary key (user_id, notification_type)
);

alter table public.notification_preferences enable row level security;

create policy "notification_preferences_self_read"
    on public.notification_preferences for select to authenticated
    using (user_id = auth.uid());

create policy "notification_preferences_self_write"
    on public.notification_preferences for insert to authenticated
    with check (user_id = auth.uid());

create policy "notification_preferences_self_update"
    on public.notification_preferences for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- Helper: upsert preference row.
create or replace function public.set_notification_preference(
    p_type text,
    p_enabled boolean
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
    insert into public.notification_preferences (user_id, notification_type, enabled, updated_at)
    values (auth.uid(), p_type, p_enabled, now())
    on conflict (user_id, notification_type)
    do update set enabled = excluded.enabled, updated_at = excluded.updated_at;
end;
$$;

grant execute on function public.set_notification_preference(text, boolean) to authenticated;

-- Touch updated_at on row update.
create or replace function public.notification_preferences_touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;

create trigger notification_preferences_touch_updated_at_trg
    before update on public.notification_preferences
    for each row execute function public.notification_preferences_touch_updated_at();
