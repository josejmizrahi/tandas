# GroupType Removal — follow-up to Audit § 5.3 #7c

> Status: **near-complete**. Swift enum gone (commit `aa99ac7`,
> SPM split sprint 2.1a). Server column drop + RPC param drop pending —
> 1 small migration + 1 fixture line + 4 iOS callsite cleanups.
> Trackeado como tarea B2.8 del sprint pre-Beta 1.

## Lo que SÍ se ejecutó

1. **`templates.config.presentation` + `defaultCategory`** — migration
   00037 (commit `32c5838`, 2026-05-07). Datos que vivían en el enum
   Swift `GroupType` se movieron al config jsonb del template.
2. **`Template.effective*` accessors** — `effectiveDisplayName`,
   `effectiveSymbolName`, `effectiveDescription`, `effectiveBullets`,
   `effectiveDefaultEventLabel`, `effectiveDefaultCategory`. Cliente
   lee del template, no del legacy enum.
3. **`Group.category` / `initials` / `avatar_url`** — migration 00036.
   Avatar ramp ahora vive en `groups.category`, no derivado de
   `groupType`.
4. **`GroupType` Swift enum DELETED** — commit `aa99ac7`, sprint 2.1a
   (SPM split a `RuulCore`). El archivo `ios/Tandas/Models/GroupType.swift`
   se borró (90 líneas). Los consumers se migraron en el mismo commit.
5. **`groups.group_type` columna** — migration 00042: `NULLABLE`,
   `DEFAULT NULL`, `COMMENT 'DEPRECATED'`. RPC `create_group_with_admin`
   ahora resuelve template y categoría desde `templates.config`,
   ignorando `p_group_type` si lo recibe.
6. **`Group.groupType` Swift property** — borrado. `Group.swift` ya
   no lo declara. `CreateGroupParams` tampoco. `MockGroupsRepository`
   ya alineado.
7. **Onboarding flow** — `FounderOnboardingCoordinator.createInitial`
   ya usa `draft.template ?? TemplateRegistry.dinnerRecurringId`.
   Cero hardcoding de `GroupType.recurringDinner`.

## Lo que falta (B2.8 del sprint actual)

1. **`seedGroup.ts:73` fixture** — pasa `p_group_type: "recurring_dinner"`.
   Cambiar a `p_base_template: "recurring_dinner"`.
2. **`GroupsRepository.swift` líneas 301, 310, 410, 422** — 4
   ocurrencias del param `p_group_type: nil`. Drop el param entirely
   del payload (RPC sigue aceptándolo NULLABLE pero no necesitamos
   pasarlo).
3. **Migration de drop**:
   - `ALTER TABLE groups DROP COLUMN group_type;`
   - Drop `p_group_type` del signature de `create_group_with_admin`.
     Crear nueva versión sin el param y migrar callers; o usar
     `DROP FUNCTION` + `CREATE FUNCTION` con la firma nueva.
4. **Verificación**: `grep -rn "GroupType\|groupType\|group_type\|p_group_type" --include="*.swift" --include="*.ts" --include="*.sql" .`
   debe retornar solo:
   - Migration history (00037, 00038, 00042) — no tocar (audit trail).
   - Esta nota.

## DoD

- [x] `grep -rn "GroupType\b" --include="*.swift" ios/` returns zero.
- [x] `Group.groupType` property eliminada.
- [x] `CreateGroupParams.groupType` eliminada.
- [x] Onboarding sin hardcoding de `GroupType.recurringDinner.rawValue`.
- [x] Founder puede crear grupo desde template "Cena recurrente" — header lee de `Template.effectiveDisplayName`.
- [ ] `seedGroup.ts` fixture migrado.
- [ ] iOS pasa de pasar `p_group_type: nil` a no pasarlo.
- [ ] `groups.group_type` column dropped en prod.
- [ ] `p_group_type` RPC param removido.
- [ ] `Plans/Active/Audit-2026-05-06.md` § 5.3 item 7c marcado shipped (✅ ya hecho 2026-05-08).

## Cuando se cierre B2.8

Mover este archivo a `Plans/Completed/GroupTypeRemoval.md` con changelog:
- Scaffolding: 2026-05-07 (32c5838)
- Swift enum delete: 2026-05-07 (aa99ac7, SPM split colateral)
- Server column drop: 2026-05-08 (B2.8)

## Costo restante

~2h: 1 migration + 4 iOS line edits + 1 fixture line + tests.
