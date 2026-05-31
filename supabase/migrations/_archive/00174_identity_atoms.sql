-- Mig 00174: Identity atoms — Layer 0 append-only audit log
--
-- Constitution: Layer 0 (Identity) had no atom table. system_events is
-- group-scoped and cannot host user-scoped events. data_deletion_log
-- (mig 00168) covers deletions only. This adds the missing audit slice:
-- signup, anon→phone promotion, and profile field mutations.
--
-- Append-only enforced by atom_guard trigger (same pattern as
-- vote_casts / system_events / data_deletion_log).
--
-- RLS: owner-only read. No INSERT policy needed because all rows arrive
-- via SECURITY DEFINER triggers; we revoke INSERT from authenticated.

create table public.identity_atoms (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    atom_type text not null check (atom_type in (
        'signup',
        'anon_promoted',
        'profile_updated'
    )),
    payload jsonb not null default '{}'::jsonb,
    occurred_at timestamptz not null default now()
);

create index identity_atoms_user_idx
    on public.identity_atoms (user_id, occurred_at desc);
create index identity_atoms_type_idx
    on public.identity_atoms (atom_type, occurred_at desc);

alter table public.identity_atoms enable row level security;

create policy "identity_atoms_self_read"
    on public.identity_atoms
    for select to authenticated
    using (user_id = auth.uid());

-- Atom guard — no UPDATE / DELETE / direct INSERT.
create or replace function public.identity_atoms_atom_guard()
returns trigger language plpgsql as $$
begin
    raise exception 'identity_atoms is append-only (Atom). Triggers only.'
        using errcode = 'check_violation';
end;
$$;

create trigger identity_atoms_atom_guard_trg
    before update or delete on public.identity_atoms
    for each row execute function public.identity_atoms_atom_guard();

revoke insert on public.identity_atoms from authenticated, anon, public;

-- Helper: emit an identity atom under SECURITY DEFINER. Each per-event
-- trigger calls this with its own atom_type + payload.
create or replace function public.emit_identity_atom(
    p_user_id uuid,
    p_atom_type text,
    p_payload jsonb
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
    insert into public.identity_atoms (user_id, atom_type, payload)
    values (p_user_id, p_atom_type, coalesce(p_payload, '{}'::jsonb));
end;
$$;

revoke execute on function public.emit_identity_atom(uuid, text, jsonb)
    from public, anon, authenticated;

-- Trigger 1: signup (auth.users INSERT)
create or replace function public.handle_identity_signup()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
    perform public.emit_identity_atom(
        new.id,
        'signup',
        jsonb_build_object(
            'is_anonymous', coalesce(new.is_anonymous, false),
            'has_email',    new.email is not null,
            'has_phone',    new.phone is not null
        )
    );
    return new;
end;
$$;
revoke execute on function public.handle_identity_signup() from public, anon, authenticated;

drop trigger if exists on_auth_user_identity_signup on auth.users;
create trigger on_auth_user_identity_signup
    after insert on auth.users
    for each row execute function public.handle_identity_signup();

-- Trigger 2: anon→phone promotion (is_anonymous true → false)
create or replace function public.handle_identity_promotion()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
    if coalesce(old.is_anonymous, false) = true
       and coalesce(new.is_anonymous, false) = false then
        perform public.emit_identity_atom(
            new.id,
            'anon_promoted',
            jsonb_build_object(
                'phone', new.phone,
                'email', new.email
            )
        );
    end if;
    return new;
end;
$$;
revoke execute on function public.handle_identity_promotion() from public, anon, authenticated;

drop trigger if exists on_auth_user_identity_promotion on auth.users;
create trigger on_auth_user_identity_promotion
    after update of is_anonymous on auth.users
    for each row execute function public.handle_identity_promotion();

-- Trigger 3: profile_updated (display_name / avatar_url change)
create or replace function public.handle_identity_profile_updated()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_changed text[] := array[]::text[];
begin
    if new.display_name is distinct from old.display_name then
        v_changed := v_changed || 'display_name';
    end if;
    if new.avatar_url is distinct from old.avatar_url then
        v_changed := v_changed || 'avatar_url';
    end if;
    -- phone/timezone/locale are intentionally excluded: phone comes via
    -- auth.users sync (already audited by signup/promotion), tz/locale
    -- are preferences low-signal for audit.

    if array_length(v_changed, 1) is not null then
        perform public.emit_identity_atom(
            new.id,
            'profile_updated',
            jsonb_build_object('fields_changed', v_changed)
        );
    end if;
    return new;
end;
$$;
revoke execute on function public.handle_identity_profile_updated() from public, anon, authenticated;

drop trigger if exists on_profile_identity_updated on public.profiles;
create trigger on_profile_identity_updated
    after update on public.profiles
    for each row execute function public.handle_identity_profile_updated();
