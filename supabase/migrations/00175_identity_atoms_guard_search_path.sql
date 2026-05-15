-- Mig 00175: Lock down search_path on identity_atoms_atom_guard.
--
-- Supabase security advisor flagged 00174's atom guard as having a
-- mutable search_path. We add the standard `set search_path = public,
-- pg_temp` qualifier (same pattern used by the other guards across the
-- codebase). The function body is unchanged — this is purely hardening.
create or replace function public.identity_atoms_atom_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
    raise exception 'identity_atoms is append-only (Atom). Triggers only.'
        using errcode = 'check_violation';
end;
$$;
