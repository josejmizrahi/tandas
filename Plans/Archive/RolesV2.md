# Roles V2 — `MemberRole` configurable per group

> Status: **foundation slice done 2026-05-09** (Gap 3 from the
> post-Gap-2 audit). Schema + permission seam shipped — Phase 2
> templates (`shared_resource`) can now declare custom roles in
> `templates.config.defaultRoles` and iOS decodes them. Phase 2 of
> RolesV2 (founder-managed UI + assign_role RPC + RLS rewire to
> consult `has_permission`) deferred to pre-Phase-5.
> Tracked en `Plans/Completed/Audit-2026-05-06.md` § 4.5 Riesgo 5.

## Phase 1 done (Gap 3)

Migration `00063_groups_roles_jsonb.sql` shipped:
- `groups.roles` jsonb default with `founder` + `member` system roles
  seeded (founder gets the V1 admin permission set;
  member gets only `createVotes` + `castVote`).
- Validation trigger on `group_members.role` — permissive: unknown
  roles raise `notice` but don't block. Strict mode lands in Phase 5.
- `has_permission(p_group_id, p_user_id, p_permission)` SECURITY
  DEFINER RPC consulting `roles[role].permissions`. Legacy `"admin"`
  aliased to `"founder"`.

iOS:
- `Permission` enum with `@codegen:enum` marker covering V1 actions
  + Phase 2/3 placeholders (`assignSlot`, `fundWithdraw`, etc.).
- `RoleDefinition` struct + `Group.roles: [String: RoleDefinition]?`
  with `effectiveRoles` fallback to `v1SystemRoles`.
- `GovernanceServiceProtocol.hasPermission(_:member:in:)` with default
  protocol extension reading from `group.roles` locally. Independent
  of `canPerform` (governance jsonb) — composes. RLS rewire to
  delegate to `has_permission()` deferred to Phase 5.

## Phase 2 (pre-Fase 5)

## Por qué

V1 trata `MemberRole` como string libre (`"admin"|"member"`) en
`group_members.role` + `GroupDetail.myRole`. Funciona para cenas pero
bloquea casos como:

- **Tandas / fondos**: `treasurer` (custodia, retira), `auditor`
  (firma para retirar pero no custodia), `member` (aporta).
- **Palcos**: `seat_owner`, `co-owner`, `guest_holder`.
- **Family-business / club**: `governance_council`, `member`,
  `observer`, `arbiter`.

Hardcodear estos en un Swift enum se vuelve un patrón roto: cada nuevo
template requeriría release coordinado iOS+server, y el principio
"templates como configuración" (Vision §Principios #2) se viola.

## Enfoque

`groups.roles` jsonb por grupo, semántica:

```jsonc
{
  "founder": { "system": true, "permissions": ["modifyGovernance"] },
  "member":  { "system": true, "permissions": [] },
  "treasurer": {
    "label": "Tesorero",
    "permissions": ["fundWithdraw", "fundAudit"],
    "max_holders": 1
  },
  "arbiter": {
    "label": "Árbitro",
    "permissions": ["closeAppeal", "voidFine"],
    "max_holders": 2
  }
}
```

`group_members.role` permanece text libre, validado por trigger contra
keys de `groups.roles`. `MemberRole` Swift enum se mantiene **solo como
helper** para los dos roles `system: true` (founder, member); cualquier
rol más allá se referencia como `String`.

## Tareas (cuando se ejecute)

1. **Schema**: agregar `groups.roles` jsonb default `{}` con los dos
   system roles. Backfill con `{"founder": {…}, "member": {…}}`.
2. **Validación**: trigger `BEFORE INSERT/UPDATE on group_members`
   verifica `role` está en keys de `groups.roles` o es system.
3. **Permission resolver**: `GovernanceService.canPerform` consulta
   `groups.roles[role].permissions ⊃ {action}` antes de fallback a
   role-name match.
4. **Templates**: `templates.config.defaultRoles` jsonb permite a
   templates declarar roles default (e.g. tanda template viene con
   treasurer + auditor pre-declarados).
5. **iOS**: `MemberRole` Swift se queda como enum para founder/member;
   un `CustomRole(name: String, label: String, permissions: Set<…>)`
   struct para el resto. `myRole` queda como `String` en `Group`/
   `GroupDetail`.
6. **UI**: `GroupRolesSheet` para founders (cuando `whoCanManageRoles`
   permita) — agregar/borrar/editar roles non-system.
7. **Asignación**: `assign_role(p_group_id, p_user_id, p_role)` RPC
   gated por `whoCanAssignRoles`. Para roles con `max_holders`,
   verificar antes.
8. **History**: `SystemEvent.roleAssigned` + `roleRevoked` para audit.

## Migrations adelantadas (cuando llegue Fase 5)

- `NN_groups_roles_jsonb.sql` — schema + backfill
- `NN_group_members_role_validation_trigger.sql` — validation
- `NN_assign_role_rpc.sql` — RPC + RLS

## DoD

- [ ] `groups.roles` jsonb existe + default seeded
- [ ] `group_members.role` validado por trigger
- [ ] `GovernanceService.canPerform` consulta `groups.roles[role].permissions`
- [ ] Templates pueden declarar `defaultRoles`
- [ ] Founders pueden crear/editar/borrar roles non-system via UI
- [ ] System events `roleAssigned`/`roleRevoked` emitidos

## Cuándo NO hacerlo

- Antes de Fase 4 (Fund). V1 no lo necesita; el churn de migrar todo
  callsite + RLS prematuro no compensa.
- Si solo hay un caso de roles custom, considerar primero si el caso
  es realmente de roles o de capability (capability vive en módulos,
  rol vive en miembros).

## Costo estimado

1-2 semanas focused (schema + trigger + RPC + iOS UI + tests +
migration de RLS policies que actualmente asumen "admin"/"member"
hardcoded).
