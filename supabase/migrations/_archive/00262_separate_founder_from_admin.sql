-- Mig 00262: Separar founder (identidad) de admin (permisos)
--
-- Hasta hoy, el rol "founder" cargaba dos cosas distintas:
--   1. IDENTIDAD: quién creó el grupo (historical, immutable)
--   2. PERMISOS: 8 capabilities (modifyGovernance, modifyRules,
--      modifyMembers, assignRoles, removeMember, voidFine,
--      closeAppeal, createVotes)
--
-- La conflación rompía dos escenarios:
--   - Founder que quiere "step back" (mantener crédito histórico
--     sin seguir siendo el admin operativo) — imposible, founder =
--     admin
--   - Co-admins ad-hoc — había que asignar founder o nada, porque
--     ningún otro rol llevaba el permission set
--
-- Esta migración separa los dos:
--   - `founder` queda como rol de IDENTIDAD: system=true, sin
--     permisos. Es solo un badge histórico. No se puede eliminar
--     (system) pero tampoco otorga capability.
--   - `admin` nuevo rol system con los 8 permisos que tenía founder.
--     Asignable / revocable / transferible como cualquier otro rol.
--   - Founder existente se mantiene en su rol founder + se le agrega
--     admin (backfill) para no romper su capacidad operativa.
--
-- Migración path safe: NO removes permissions de founder en esta mig
-- para mantener back-compat con call sites legacy que aún chequean
-- `member.isFounder`. Una mig posterior (P2) puede vaciar founder
-- una vez que iOS migre a `member.isAdmin` / `has_permission(...)`
-- en todos sus checks.

-- =============================================================================
-- 1. Default seed: groups.roles incluye admin
-- =============================================================================
--
-- Tres roles system going forward: founder (identidad), admin
-- (permisos), member (baseline). Templates pueden agregar custom
-- (treasurer, etc.) via seed_template_roles (mig 00067).

alter table public.groups
  alter column roles set default jsonb_build_object(
    'founder', jsonb_build_object(
      'system', true,
      'permissions', jsonb_build_array(
        -- Mantenemos los 8 permisos en founder por back-compat.
        -- iOS migration P2 los vaciará una vez que todos los checks
        -- usen admin / has_permission. Sin esto, un founder solo (sin
        -- admin agregado) perdería capacidades durante el rollout.
        'modifyGovernance',
        'modifyRules',
        'modifyMembers',
        'assignRoles',
        'removeMember',
        'voidFine',
        'closeAppeal',
        'createVotes'
      )
    ),
    'admin', jsonb_build_object(
      'system', true,
      'permissions', jsonb_build_array(
        'modifyGovernance',
        'modifyRules',
        'modifyMembers',
        'assignRoles',
        'removeMember',
        'voidFine',
        'closeAppeal',
        'createVotes'
      )
    ),
    'member', jsonb_build_object(
      'system', true,
      'permissions', jsonb_build_array(
        'createVotes',
        'castVote'
      )
    )
  );

-- =============================================================================
-- 2. Backfill: cada grupo existente recibe el admin role en su catalog
-- =============================================================================

update public.groups
   set roles = roles || jsonb_build_object(
     'admin', jsonb_build_object(
       'system', true,
       'permissions', jsonb_build_array(
         'modifyGovernance', 'modifyRules', 'modifyMembers',
         'assignRoles', 'removeMember', 'voidFine',
         'closeAppeal', 'createVotes'
       )
     )
   )
 where roles is not null
   and not (roles ? 'admin');

-- =============================================================================
-- 3. Backfill: cada member con role 'founder' también recibe 'admin'
-- =============================================================================
--
-- Sin esto un founder existente pierde permisos al momento que la mig
-- futura limpie founder.permissions. Lo hacemos ahora aunque founder
-- aún tenga permisos, así el estado queda correcto independientemente
-- de cuándo iOS migre.
--
-- Match path: roles is a jsonb array string array ["founder", ...] OR
-- a legacy text column. La columna group_members.roles fue migrada
-- a jsonb array en mig 00019; usamos esa shape aquí.

update public.group_members
   set roles = roles || jsonb_build_array('admin')
 where roles ? 'founder'
   and not (roles ? 'admin');

-- =============================================================================
-- 4. seed_template_roles: preservar admin además de founder/member
-- =============================================================================
--
-- La función existente preserva founder + member al overwrite con
-- template.config.defaultRoles. Necesita preservar admin también para
-- no perderlo en cualquier seed posterior.

create or replace function public.seed_template_roles(
  p_template_id text,
  p_group_id uuid
) returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_default_roles jsonb;
  v_current_roles jsonb;
  v_has_custom_role boolean;
  v_admin_role jsonb;
  v_founder_role jsonb;
  v_member_role jsonb;
  g public.groups;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  if not public.has_permission(p_group_id, uid, 'modifyGovernance') then
    raise exception 'modifyGovernance permission required' using errcode = '42501';
  end if;

  select config -> 'defaultRoles'
    into v_default_roles
    from public.templates
   where id = p_template_id;

  if v_default_roles is null or jsonb_typeof(v_default_roles) <> 'object' then
    select * into g from public.groups where id = p_group_id;
    return g;
  end if;

  select roles into v_current_roles from public.groups where id = p_group_id;
  select exists (
    select 1
    from jsonb_each(coalesce(v_current_roles, '{}'::jsonb)) r(key, value)
    where key not in ('founder', 'admin', 'member')
  ) into v_has_custom_role;

  if v_has_custom_role then
    select * into g from public.groups where id = p_group_id;
    return g;
  end if;

  -- Preserve los 3 system roles aunque template's defaultRoles los
  -- omita. Sin esto un template que solo declara custom roles
  -- (treasurer, captain) borraría founder/admin/member.
  v_founder_role := coalesce(
    v_current_roles -> 'founder',
    v_default_roles -> 'founder'
  );
  v_admin_role := coalesce(
    v_current_roles -> 'admin',
    v_default_roles -> 'admin',
    jsonb_build_object(
      'system', true,
      'permissions', jsonb_build_array(
        'modifyGovernance', 'modifyRules', 'modifyMembers',
        'assignRoles', 'removeMember', 'voidFine',
        'closeAppeal', 'createVotes'
      )
    )
  );
  v_member_role := coalesce(
    v_current_roles -> 'member',
    v_default_roles -> 'member'
  );

  update public.groups
     set roles = v_default_roles
       || jsonb_build_object('founder', v_founder_role)
       || jsonb_build_object('admin',   v_admin_role)
       || jsonb_build_object('member',  v_member_role)
   where id = p_group_id
   returning * into g;

  return g;
end;
$$;

comment on function public.seed_template_roles(text, uuid) is
  'Seeds groups.roles desde templates.config.defaultRoles. Preserva los 3 system roles (founder/admin/member) — los template defaults pueden override sus permisos pero no eliminarlos del catalog. Skip silently si el grupo ya tiene roles custom (idempotente).';
