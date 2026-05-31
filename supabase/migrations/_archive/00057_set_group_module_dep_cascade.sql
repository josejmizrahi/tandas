-- 00057 — Module dependency cascades in set_group_module.
--
-- Audit: Plans/Active/Primitives.md § 3 (Slice 3 followup).
--
-- Context:
--   Slice 3 (mig 00055) introduced `set_group_module(p_group_id,
--   p_module_slug, p_enabled)` as the canonical write-path for
--   `groups.active_modules`. iOS `ModuleRegistry.validate(ids:)`
--   already enforces the V1 dep graph client-side, but the RPC
--   itself accepts any single-module flip without checking deps.
--
--   This means admins can drive the group into a state where:
--     - `appeal_voting` is on but `basic_fines` is off  (broken;
--       resolver compensates because `appealsEnabled` requires both,
--       but the data state lies about admin intent).
--     - `check_in` is on but `rsvp` is off  (same).
--     - `basic_fines` is on but `rsvp`/`check_in` are off  (same).
--
--   None of the above currently cause a crash because the iOS
--   resolver returns false for the dependent capability whenever any
--   link in the chain is missing. But:
--     1. The write-path no longer reflects user intent. Admin says
--        "enable basic_fines" and the data ends up half-baked.
--     2. Any future server-side code that iterates `active_modules`
--        without re-running validation gets fooled.
--     3. The cascade rules now live only in iOS; SQL drift is a
--        latent risk.
--
--   This migration brings the server in line with iOS by adding a
--   transitive cascade:
--     - ENABLE X  → also enable every module in deps_of(X) closure.
--     - DISABLE X → also disable every module in dependents_of(X)
--                   closure.
--
-- V1 dep graph (matches `ios/.../PlatformModules/V1Modules.swift`):
--
--     basic_fines    requires {rsvp, check_in}
--     check_in       requires {rsvp}
--     appeal_voting  requires {basic_fines}
--     rotating_host  requires {}
--     rsvp           requires {}
--
-- Pre-computed closures (hardcoded as static jsonb so this RPC has no
-- DB lookup per call):
--
--     deps_closure:
--       basic_fines    → [rsvp, check_in]
--       check_in       → [rsvp]
--       appeal_voting  → [basic_fines, check_in, rsvp]
--       rotating_host  → []
--       rsvp           → []
--
--     dependents_closure:
--       rsvp           → [check_in, basic_fines, appeal_voting]
--       check_in       → [basic_fines, appeal_voting]
--       basic_fines    → [appeal_voting]
--       rotating_host  → []
--       appeal_voting  → []
--
--   When a 6th V1+ module ships (rotation, fund, slot, asset, …) the
--   closures are extended in lockstep with iOS V1Modules.swift. The
--   data lives in two places by design — V1 has 5 modules and the
--   server-side cascade is a small enough surface that a runtime
--   lookup table isn't worth the complexity.
--
-- Idempotency: cascade-adds skip slugs already present; cascade-removes
-- skip slugs already absent. Calling `set_group_module(g, basic_fines,
-- true)` twice in a row is a no-op the second time.
--
-- Unknown slugs: if `p_module_slug` isn't in the closure map, the
-- function still toggles the slug itself (no cascade). This keeps
-- forward-compat for any module added to iOS V1Modules.swift but not
-- yet wired into this migration's closure — at worst the admin
-- toggles only the named module.
--
-- Rollback: 00057_rollback.sql restores the slice 3 (00055) behaviour
-- (no cascade). Data state at rollback time is preserved (cascades
-- already applied stay).

create or replace function public.set_group_module(
  p_group_id    uuid,
  p_module_slug text,
  p_enabled     boolean
) returns public.groups
language plpgsql security definer set search_path = public as $$
declare
  g public.groups;
  v_modules jsonb;
  -- Transitive deps closure: deps_closure->slug = jsonb array of every
  -- module the slug requires (directly or transitively).
  v_deps_closure constant jsonb := jsonb_build_object(
    'basic_fines',   jsonb_build_array('rsvp', 'check_in'),
    'check_in',      jsonb_build_array('rsvp'),
    'appeal_voting', jsonb_build_array('basic_fines', 'check_in', 'rsvp'),
    'rotating_host', jsonb_build_array(),
    'rsvp',          jsonb_build_array()
  );
  -- Transitive dependents closure: dependents_closure->slug = jsonb
  -- array of every module that requires the slug (directly or
  -- transitively).
  v_dependents_closure constant jsonb := jsonb_build_object(
    'rsvp',          jsonb_build_array('check_in', 'basic_fines', 'appeal_voting'),
    'check_in',      jsonb_build_array('basic_fines', 'appeal_voting'),
    'basic_fines',   jsonb_build_array('appeal_voting'),
    'rotating_host', jsonb_build_array(),
    'appeal_voting', jsonb_build_array()
  );
  v_to_apply text;
begin
  if p_module_slug is null or length(trim(p_module_slug)) = 0 then
    raise exception 'set_group_module: p_module_slug is required';
  end if;

  if p_enabled is null then
    raise exception 'set_group_module: p_enabled is required';
  end if;

  if not public.is_group_admin(p_group_id, auth.uid()) then
    raise exception 'only admins can change group modules';
  end if;

  select active_modules into v_modules
    from public.groups
   where id = p_group_id
   for update;

  if not found then
    raise exception 'group not found: %', p_group_id;
  end if;

  if p_enabled then
    -- Add the slug + every dep (transitive). Skip duplicates so the
    -- final array has no repeated entries.
    if not (v_modules ? p_module_slug) then
      v_modules := v_modules || jsonb_build_array(p_module_slug);
    end if;
    for v_to_apply in
      select jsonb_array_elements_text(coalesce(v_deps_closure -> p_module_slug, '[]'::jsonb))
    loop
      if not (v_modules ? v_to_apply) then
        v_modules := v_modules || jsonb_build_array(v_to_apply);
      end if;
    end loop;
  else
    -- Remove the slug + every dependent (transitive).
    v_modules := v_modules - p_module_slug;
    for v_to_apply in
      select jsonb_array_elements_text(coalesce(v_dependents_closure -> p_module_slug, '[]'::jsonb))
    loop
      v_modules := v_modules - v_to_apply;
    end loop;
  end if;

  update public.groups
     set active_modules = v_modules,
         updated_at = now()
   where id = p_group_id
   returning * into g;

  return g;
end;
$$;

comment on function public.set_group_module(uuid, text, boolean) is
  'Toggles module slug membership in groups.active_modules with transitive dep/dependent cascades. Admin-only. Trigger from mig 00049 derives groups.fines_enabled when slug=basic_fines. Closure tables hardcoded per ios/.../V1Modules.swift; new modules require lockstep update. See Plans/Active/Primitives.md § 3.';
