# Phase 2 Readiness — 2026-05-09

> Status: punto de control. Lista de qué falta cerrar antes de poder
> arrancar Phase 2 con conciencia tranquila. Versión vigente al
> 2026-05-09 post-Slice 3 + Slice 3.5 + Slice 3 followup + Slice E.1.
>
> Audiencia: founder + cualquier sesión futura (humana o IA) que vaya
> a empezar trabajo de Phase 2 (Rotation / Slot / Fund / Asset).

---

## 0. Decisión que NO depende de este doc

`Plans/Active/Beta1.md` § 6 dice que la primitiva específica de
Phase 2 (Rotation universal vs Slot/Booking vs Asset vs Fund vs
mezcla mínima) la **decide el journal de cenas** o el founder
explícitamente. Este doc no opina sobre esa decisión — solo lista
qué infra técnica necesita estar verde **independientemente de cuál
primitiva se elija**.

---

## 1. Lo que ya está verde (no bloquea Phase 2)

### Plataforma core (L1 según `Primitives.md` § 2)

- ✅ **Group / Identity / Membership** — vivos, estables.
- ✅ **Resource** polimórfico — `resources` table + `LiveResourceRepository`
  (Plan 1, mig 00040). `Event` conforma `Resource` directo, `EventResource`
  wrapper eliminado.
- ✅ **Rule** primitive — `Rule.swift` platform shape + engine puro
  (`supabase/functions/_shared/ruleEngine.ts`).
- ✅ **SystemEvent** atom + History projection — patrón documentado
  en `Primitives.md` § 1.
- ✅ **Module + Registry + Resolver** tripleta — `GroupModule.swift`,
  `ModuleRegistry.swift`, `CapabilityResolver.swift`. 5 V1 modules
  declarados en `V1Modules.swift`.

### Module write-path (Primitives.md § 3 — basic_fines como caso de prueba)

- ✅ **Slice 1** (mig 00049) — trigger sincroniza
  `groups.fines_enabled ↔ ('basic_fines' = ANY(active_modules))`.
- ✅ **Slice 2** (commit `62adfa9`) — 5 read-path callsites migrados
  a `CapabilityResolver`.
- ✅ **Slice 3** (mig 00055, commit `924cfd1`) — write-path via RPC
  `set_group_module(p_group_id, p_module_slug, p_enabled)`.
  Genérico sobre slug — **cualquier `GroupModule` futuro reutiliza
  este write-path sin RPC nueva**.
- ✅ **Slice 3 followup** (mig 00057, commit `a31909c`) — cascade
  transitivo de deps en el RPC. Closures jsonb hardcoded espejo de
  iOS `V1Modules.swift`. Test `transitiveClosures_matchSqlTables`
  guarda paridad iOS↔SQL pre-deploy.
- ✅ **Slice 3.5** (mig 00056, commit `a0810ba`) — 3rd SoT
  (`groups.settings.finesEnabled`) eliminado. Dormant write-only
  state ya no existe.

### Rules write-path

- ✅ **Slice E.1** (PR #TBD, 2026-05-09) — view callsites en platform
  shape (`name`/`isActive`), `setEnabled` dual-write `enabled` +
  `is_active`. Cierra divergencia silenciosa entre los dos booleans.

### Polymorphic infra (audit § 5.3)

- ✅ Item 9 — `fines.resource_id` + `fine_review_periods.resource_id`
  polimorfizados (mig 00041, 00050).
- ✅ Item 10 — Stable `rule_id` (slug) en `GroupModule.providedRules`
  (commits previos a este sprint).
- ✅ Item 11 — `events_to_resources_dual_write` activo (mig 00039).

---

## 2. Lo que falta cerrar antes de Phase 2

### 2.1 Slice 4 del Module SoT (sin gating técnico, sí gating temporal)

> **Gate**: 2 semanas de paridad con el trigger 00049 verde. Trigger
> añadido 2026-05-08; ventana cierra ≥ 2026-05-22.
>
> **No bloqueante** para empezar Phase 2. La columna `groups.fines_enabled`
> dropable después del 22; Phase 2 puede arrancar antes y la columna
> queda dormante hasta entonces.

Tareas cuando llegue 2026-05-22:

- [ ] Migration `00058`: `alter table groups drop column fines_enabled`.
  Drop también `groups_basic_fines_consistent` constraint y el trigger
  (ya no necesario sin la columna).
- [ ] iOS: drop `Group.finesEnabled` field + decoder + init en
  `Group.swift`. Drop fallback en `MockGroupsRepository.setModule`
  (ya no deriva, solo escribe `active_modules`).
- [ ] Update `MockGroupsRepositoryTests` — eliminar tests que asertean
  `g.finesEnabled` directo (ya no existe).
- [ ] Audit invariant chequeado vía MCP antes de drop:
  `select count(*) from groups where fines_enabled <> ('basic_fines' = ANY(active_modules))` → debe ser 0.

### 2.2 Slice E.2 — drop legacy rules columns

> **Gate**: macOS session con `xcodebuild` para verificar que el
> model collapse no regresiona views.
>
> **Bloquea**: Phase 4 custom rule editor (necesita schema limpio).
> **No bloquea**: Phase 2 directamente. Phase 2 candidates (Rotation,
> Slot, Fund, Asset) escriben rules nuevas via `create_initial_rule`
> que ya escribe ambas formas, así que Phase 2 puede arrancar con
> deuda viva en columnas legacy.

Plan completo en `RulesPlatformOnly.md` § Slice E.2. Resumen:

- iOS models drop `code`, `title`, `description`, `enabled`, `status`,
  `action` storage; promueven `name`/`isActive`/`slug`/`trigger`/
  `conditions`/`consequences` a stored fields.
- `LiveRuleRepository.createInitialRules.Params` envía platform shape.
- Server: rewrite `create_initial_rule` + `seed_dinner_template_rules`
  para escribir SOLO platform.
- Migration: `alter table rules drop column code, title, description,
  trigger, action, enabled, status, exceptions, approved_via_vote_id`.

Costo estimado: 4-6h focused **con build access**.

### 2.3 Items que NO son gating de Phase 2 (deferribles)

- **`GovernanceRulesJsonb`** — refactor pre-Phase 4 (Fund agrega
  primer `whoCan*` nuevo). No urgente para Phase 2 candidates.
  Plan en `Plans/Active/GovernanceRulesJsonb.md`.
- **`RolesV2`** — refactor pre-Phase 5 (proposals + roles
  configurables). No urgente para Phase 2.
  Plan en `Plans/Active/RolesV2.md`.
- **`SystemEventsArchival`** — implementación pre-Phase 4 (volumen).
  Documentación en `Plans/Active/SystemEventsArchival.md`.
- **`EditMembersSheet`** — P1 estructural (founder se va) pero
  ortogonal a Phase 2 primitives. Audit § 5.2 item 4.

---

## 3. Cómo arrancar Phase 2 cuando se tome la decisión

Una vez elegida la primitiva (e.g. Rotation), el flujo limpio es:

### 3.1 Declaración del módulo (iOS)

```swift
// ios/Packages/RuulCore/Sources/RuulCore/PlatformModules/V1Modules.swift
public extension GroupModule {
    public static let rotation = GroupModule(
        id: "rotation",
        name: "Rotación",
        description: "...",
        providedRules: [...],
        providedResourceTypes: [.rotation],   // nuevo case en ResourceType
        providedSystemEventTypes: [.rotationAdvanced, ...],
        providedTabs: [],                      // o ["rotation"] si tab dedicado
        dependencies: [...],                   // e.g. ["rsvp"] si el caso lo pide
        conflictsWith: []
    )
}

ModuleRegistry.v1Modules.append(.rotation)
```

### 3.2 Closure tables del cascade (server + iOS)

Hay que extender en lockstep:

- **`mig 00057`** (o un follow-up `mig 0005N`) — añadir entradas a
  `v_deps_closure` y `v_dependents_closure` para el slug nuevo.
- **`ModuleRegistry.transitiveDependencies(of:)` /
  `transitiveDependents(of:)`** — automáticamente picks up del nuevo
  módulo porque hace BFS sobre `v1Modules`.
- **`MockGroupsRepositoryTests.transitiveClosures_matchSqlTables`** —
  añadir asserts literales para el slug nuevo.

### 3.3 Resource + Rule scaffolding

- Nuevo `ResourceType` case (e.g. `.rotation`).
- Resource record en `resources` table — schema polimórfico ya
  acepta cualquier `resource_type`.
- Rule engine: nuevo evaluator si el módulo tiene reglas propias.
  Patrón establecido en `_shared/ruleEngine.ts`.
- iOS: `RotationResource` (o lo que sea) conformando `Resource`
  directo, igual que `Event`.

### 3.4 Read-path

`CapabilityResolver` ya soporta `availableResourceTypes(for:template:)`
y `supports(resourceType:in:template:)`. Ningún cambio nuevo necesario
si el módulo declara correctamente sus `providedResourceTypes`.

### 3.5 Write-path

`set_group_module` RPC ya genérico — toggling el módulo nuevo
funciona out-of-the-box. Cascade automático si las closure tables
están actualizadas.

---

## 4. Resumen ejecutivo (TL;DR)

**Phase 2 puede arrancar HOY** si la decisión se toma. Lo único
que cambia entre hoy y "post-Slice 4 + post-E.2" es:

- **Hoy**: la columna legacy `groups.fines_enabled` y las columnas
  legacy de `rules` siguen existiendo en cohabitación. No estorban
  trabajo nuevo.
- **2026-05-22+**: drop de la columna `fines_enabled` (Slice 4).
- **Post-macOS-session**: drop de columnas legacy de `rules` (E.2).

**No hay primitiva nueva que requiera más infra del resolver / module
registry / cascade**. La declaración de un nuevo `GroupModule` + un
nuevo case en `ResourceType` + actualizar las closure tables (en SQL
+ test paridad) es todo lo que cuesta.

---

## 5. Referencias cruzadas

- `Plans/Active/Primitives.md` — niveles L1–L5, regla canónica de
  Resource, stack Role/Permission/Policy, estado de Slices 1-4.
- `Plans/Active/RulesPlatformOnly.md` — plan E.1 (done) + E.2 (pending).
- `Plans/Active/Audit-2026-05-06.md` — audit canónico, items
  shipped en `§5.3`.
- `Plans/Active/Beta1.md` — freeze levantado, journal de cenas, gate
  para decisión Phase 2.
- `supabase/migrations/00049_*.sql`, `00055_*.sql`, `00056_*.sql`,
  `00057_*.sql` — módulo SoT consolidación completa.
- `ios/Packages/RuulCore/Sources/RuulCore/Capabilities/CapabilityResolver.swift` — seam de runtime modularity.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModules/V1Modules.swift` — registry V1.
