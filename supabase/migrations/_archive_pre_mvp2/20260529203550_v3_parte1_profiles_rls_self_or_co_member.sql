-- V3 PARTE 1 — RLS profiles cross-tenant leak fix
--
-- Estado previo: `profiles_select_authenticated` USING (true) → any
-- authenticated puede leer cualquier profile (incluido phone). Drift
-- doctrinal: la doctrina de tenancy (D-1, GroupPrimitives) dice que
-- cross-tenant lo único legible es lo derivable de invites/co-membership.
--
-- Doctrina elegida (Opción 1 del plan, §M PARTE 1):
--   SELECT profile permitido si:
--     - es el propio profile del caller, O
--     - existe co-membership activa/provisional con el caller en al
--       menos un grupo común.
--
-- iOS no toca `profiles` directamente (audit `Packages/RuulCore`): todo
-- pasa por RPCs (`my_profile`, `group_members`, `update_my_profile`).
-- Por eso el blast radius de este DROP es ~0: el único riesgo serían
-- queries via REST PostgREST con `from('profiles')`, y no las hay.
--
-- Atom guards no aplican (profiles no es atom).

DROP POLICY IF EXISTS profiles_select_authenticated ON public.profiles;

CREATE POLICY profiles_select_self_or_co_member
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (
    id = (SELECT auth.uid())
    OR id IN (
      SELECT gm2.user_id
        FROM public.group_memberships gm2
       WHERE gm2.group_id IN (
         SELECT gm1.group_id
           FROM public.group_memberships gm1
          WHERE gm1.user_id = (SELECT auth.uid())
            AND gm1.status IN ('active','provisional')
       )
         AND gm2.status IN ('active','provisional')
    )
  );

COMMENT ON POLICY profiles_select_self_or_co_member ON public.profiles IS
  'V3 PARTE 1: replaces profiles_select_authenticated. Cross-tenant leak fix — caller can SELECT only own profile or profiles of co-members in shared groups (active/provisional). iOS reads profiles exclusively via RPCs that pre-join membership; PostgREST direct reads are not used.';
