# Nivel 1 — Group / Dominio social: gaps + rediseño

**Fecha:** 2026-05-15
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Constitución:** `Plans/Active/Constitution.md` (canónico 2026-05-13)
**Jerarquía:** `Plans/Active/HierarchyReference.md` §1 — Layer 1 (Subject/Domain)
**Migraciones base:** `00001_core_schema.sql` (`groups`), `00019_*` (governance jsonb), `00055_*` (`set_group_module`), `00177_*` (archive lifecycle), `00178_*` (group system_events), `00183_*` (`regenerate_invite_code`)
**Spec hermano:** `docs/superpowers/specs/2026-05-14-level-0-identity-redesign.md` (Nivel 0 — Identity)

## Problema

`HierarchyReference.md` define **Nivel 1 = Subject / Domain**: "el grupo como dominio social persistente". Vive en la tabla `groups`. El BE es robusto: jsonb governance/settings/active_modules, RLS `groups_update_admin`, 6 RPCs scoped al grupo entero, lifecycle archive/unarchive, atom trail vía `system_events` con 6 tipos group-level (`groupCreated`, `groupRenamed`, `governanceUpdated`, `inviteCodeRotated`, `memberJoined`, `memberLeft`).

El FE expone una rebanada delgada y la fragmenta en **5 sheets distintas** sin punto de entrada único:

1. **No hay home dedicado al grupo.** El usuario nunca ve "el grupo entero". Hay `GroupSwitcherSheet` (lista de grupos), `GroupInfoSheet` (invite + miembros + leave), `GroupSettingsSheet` (vocabulary + 1 toggle de módulo), `GovernanceSettingsView` (read-only governance), `GroupRulesSettingsView` (presets). Cinco superficies para una sola entidad. El rename y la mayoría de columnas mutables son inalcanzables.

2. **Tras Nivel 0 Pass 1, "Este Grupo" perdió home.** El spec de Nivel 0 borró `SettingsTabView` que renderaba la sección "Este Grupo" al fondo del Profile. Ese contenido (miembros / governance / leave) ahora vive solo en `GroupInfoSheet`, que se abre tap-en-nombre-del-grupo desde el header de `HomeView`. No hay surface persistente.

3. **5 de 5 módulos** del catálogo (`basic_fines`, `rotating_host`, `rsvp`, `check_in`, `appeal_voting`) son toggleables vía `set_group_module` RPC, pero `GroupSettingsSheet` solo expone uno (`basic_fines`). Los otros 4 son invisibles.

4. **`regenerate_invite_code` RPC** (mig 00183) está implementado, RLS-gated por `Permission.modifyGovernance`, y emite `inviteCodeRotated` system_event. Sin UI. Para rotar un código tras un share accidental el usuario debe contactar soporte.

5. **`groups.name` y `groups.description`** son mutables (`groups_update_admin` RLS) pero el FE las trata como read-only post-creación. El único set viable es onboarding founder.

6. **`updateAvatar(groupId:data:contentType:)`** está implementado en `GroupsRepository`. Sin UI — el FE no permite cambiar la foto del grupo.

7. **`archive_group` / `unarchive_group`** existen como RPCs (mig 00177). El founder puede listar archivados (`groups_select_archived_founder` RLS), pero no hay UI de "papelera" ni de restaurar.

8. **6 tipos de `system_events` group-level** se emiten (mig 00178) pero el FE no consume nada. Debería existir un activity feed del grupo que muestre "Ana cambió la governance hace 2h", "Se rotó el código de invitación hace 3 días", etc.

9. **`groups.governance` jsonb** es mutable y RLS lo permite, pero el FE solo expone "presets" en `GroupRulesSettingsView`. El builder granular (custom thresholds, custom roleGate por action, etc.) no existe — diferido a un spec posterior pero el wire de los presets debe vivir aquí.

10. **`groups.settings`** tiene 12+ keys (eventVocabulary, frequencyType, frequencyConfig, rotationMode, finesEnabled, gracePeriodEvents, noShowGraceMinutes, autoGenerateEvents, blockUnpaidAttendance, fundEnabled, fundBalance, fundTarget, fundMinParticipants). El FE expone solo `eventVocabulary`.

11. **`groups.currency` y `groups.timezone`** son mutables. Sin UI post-creación.

12. **GroupSwitcher chrome** funciona pero no diferencia entre tap-para-cambiar y tap-para-ver-detalles. El usuario no sabe que ahí "vive" el grupo.

## Objetivo

Que `Nivel 1` tenga un home dedicado en el shell — `GroupHomeView` — donde el usuario llega tap-en-nombre-del-grupo y encuentra:

- Toda la identidad del grupo en una hero card editable (avatar, nombre, código de invitación)
- Configuración completa del grupo (vocabulary, currency, timezone, los 5 módulos, governance presets)
- Activity feed del grupo (consume `system_events` filtrados por `group_id`)
- Acceso a miembros (lo que hoy es `GroupInfoSheet` se absorbe)
- Acciones avanzadas (rotar código, archivar, salir)
- Footer founder-only con "papelera" (grupos archivados restaurables)

Las 5 sheets actuales (`GroupSwitcherSheet` se queda — es navegación, no contenido; las otras 4 se absorben o se vuelven subscreens de `GroupHomeView`).

## Approach — seis pasadas

Cada pasada es un PR mergeable. Order matters: Pass 2-6 dependen del entry point creado en Pass 1.

### Pass 1 · Crear `GroupHomeView` y consolidar las 4 sheets (1 sesión)

**Objetivo:** un solo home para el grupo. Las 4 sheets actuales que muestran info del grupo se transforman en subscreens o se borran.

| Archivo | Acción | Notas |
|---|---|---|
| `Features/Group/Views/GroupHomeView.swift` | **NUEVO** (~280 L) | Hero (avatar + nombre + código) + 5 secciones: Configuración, Módulos, Miembros, Actividad, Avanzado |
| `Features/Group/GroupHomeCoordinator.swift` | **NUEVO** (~120 L) | Carga `Group` + `[GroupModule]` + `[GroupPolicy]` + member count |
| `Features/Groups/Switcher/GroupInfoSheet.swift` | **DELETE** (~270 L) | Su contenido se absorbe en `GroupHomeView` |
| `Features/Groups/Settings/GroupSettingsSheet.swift` | **DELETE** | El 1 toggle se absorbe en sección Módulos de `GroupHomeView` |
| `Features/Groups/Settings/GovernanceSettingsView.swift` | **MOVE → `Features/Group/Subscreens/GovernanceView.swift`** | Sigue siendo subscreen, pero accesible desde `GroupHomeView` |
| `Features/Groups/Settings/GroupRulesSettingsView.swift` | **MOVE → `Features/Group/Subscreens/RulePresetsView.swift`** | Idem |
| `Features/Shell/RootShellState.swift` | **Modify** | Agregar `case groupHome` (nueva sheet route) |
| `Features/Shell/RootShellSheets.swift` | **Modify** | Agregar handler para `.groupHome` |
| `Features/Shell/RootRouter.swift` | **Modify** | Agregar `openGroupHome()` |
| `Features/Home/HomeView.swift` (group switcher chrome) | **Modify** | Tap-en-nombre-del-grupo abre `GroupHomeView` (no `GroupInfoSheet`). Long-press abre `GroupSwitcherSheet`. Diferenciar afford |
| `Features/Profile/Views/MyProfileView.swift` (Nivel 0) | **Modify** | "Mis grupos (3)" navRow nueva en sección TU ACTIVIDAD → abre lista cross-group desde Profile (lista usa GroupSwitcherSheet o navega a un GroupListView simple) |

**Boundaries:** Pass 1 NO toca BE. NO agrega nuevas mutaciones — solo reagrupa las que ya existen.

**Acceptance Pass 1:**
- Tap-en-nombre-del-grupo en HomeView abre `GroupHomeView`.
- `GroupInfoSheet`, `GroupSettingsSheet` no existen como files.
- `GroupHomeView` muestra todo lo que las 4 sheets viejas mostraban (member count, governance link, leave, vocabulary, fines toggle).
- Build clean + smoke en simulador.

### Pass 2 · Wire-up de campos `groups` sub-utilizados (1 sesión)

**Objetivo:** exponer rename, change avatar, regenerar código, currency, timezone, los 5 módulos. Cero migraciones.

**Repo extensions** (`GroupsRepository.swift`):

```swift
public protocol GroupsRepository: Actor {
    // ... existing methods ...

    // NEW
    func rename(groupId: UUID, name: String) async throws
    func updateDescription(groupId: UUID, description: String) async throws
    func updateCurrency(groupId: UUID, currency: String) async throws
    func updateTimezone(groupId: UUID, tz: String) async throws
}
```

`updateAvatar`, `setModule`, `regenerateInviteCode`, `archive`, `unarchive` ya existen.

**Subscreens nuevas en `Features/Group/Subscreens/`:**

| Archivo | Tamaño | Qué hace |
|---|---|---|
| `EditGroupIdentitySheet.swift` | ~200 L | Rename + descripción + cover/avatar picker. Bottom sheet medium-detent. |
| `ModulesPickerView.swift` | ~180 L | Lista los 5 módulos del catálogo (`modules` table o hardcoded fallback con `ModuleRegistry`). Toggle por módulo → `setGroupModule` RPC. Disabled state si module tiene dependencies sin satisfacer (read `GroupModule.dependencies` + `conflictsWith`). |
| `GroupCurrencyPickerView.swift` | ~120 L | Lista corta (MXN, USD, EUR, GBP, ARS, BRL, CLP, COP, PEN). Tap → `updateCurrency`. Default highlight = current. |
| `GroupTimezonePickerView.swift` | ~140 L | Idéntica a `TimezonePickerView` de Nivel 0 — refactorizar a un `TimezonePicker` shared en `RuulUI/Patterns/`. Tap → `updateTimezone`. |
| `RegenerateInviteCodeSheet.swift` | ~150 L | Confirmation dialog ("Esto invalidará el código actual"). Tap → `regenerateInviteCode` RPC. Mostrar nuevo código grande con copy + share buttons. |

**`GroupHomeView` añade secciones:**

```
├─ Configuración ─────────────────────────┤
│  ✏️  Nombre y foto                   →  │  → EditGroupIdentitySheet
│  💱  Moneda            MXN          →   │  → GroupCurrencyPickerView
│  🕐  Zona horaria      America/MX   →   │  → GroupTimezonePickerView
│  🧩  Módulos           3 activos    →   │  → ModulesPickerView
│
├─ Avanzado ──────────────────────────────┤
│  🔄 Rotar código de invitación      →   │  → RegenerateInviteCodeSheet
│  🚪 Salir del grupo                     │
```

**Acceptance Pass 2:**
- Rename funciona (admin-only via RLS). Cambio se refleja en GroupSwitcher después.
- Toggle de cualquiera de los 5 módulos funciona; conflictos se bloquean en UI.
- Cambiar currency rota formateo de fines/ledger.
- Cambiar timezone rota formateo de fechas en HomeView.
- Rotar código emite `inviteCodeRotated` system_event y devuelve nuevo código.

### Pass 3 · Group activity feed (1 sesión)

**Objetivo:** consumir los 6 tipos de `system_events` group-level y mostrarlos como timeline.

**Repo:**

`Repositories/GroupActivityRepository.swift` (NUEVO, ~80 L):

```swift
public protocol GroupActivityRepository: Actor {
    func loadRecent(groupId: UUID, limit: Int) async throws -> [GroupActivityItem]
}

public struct GroupActivityItem: Sendable, Identifiable {
    public let id: UUID
    public let kind: Kind
    public let actorUserId: UUID?
    public let payload: [String: AnyCodable]
    public let occurredAt: Date

    public enum Kind: String, Sendable, Codable {
        case groupCreated, groupRenamed, governanceUpdated,
             inviteCodeRotated, memberJoined, memberLeft, moduleToggled
    }
}
```

Live: `from("system_events").select("id, event_type, actor_user_id, payload, occurred_at").eq("group_id", groupId).in("event_type", ["group_created", "group_renamed", ...]).order("occurred_at", ascending: false)`.

**Subscreen:**

`Features/Group/Subscreens/GroupActivityView.swift` (~220 L) — feed agrupado por día:

```
HOY
  ✏️  Ana cambió el nombre del grupo
  🔄  José rotó el código de invitación
AYER
  ➕  Carla se unió al grupo
HACE 3 DÍAS
  ⚙️  José actualizó la governance
```

Texto humano por kind. Avatar del actor cuando aplique. No interactivo (audit trail).

**`GroupHomeView`** añade row "Actividad del grupo" → `GroupActivityView`.

**Acceptance Pass 3:**
- Cualquier mutación del grupo (rename, code rotation, governance change) aparece en el feed dentro de 1 segundo (refresh manual + realtime channel optional).

### Pass 4 · Archive / restore (papelera para founder) (1 sesión)

**Objetivo:** UI para archivar grupo + restaurar grupos archivados.

**Subscreens:**

`Features/Group/Subscreens/ArchiveGroupSheet.swift` (~140 L):
- Confirmation con warning: "Los miembros perderán acceso. El grupo aparecerá en tu papelera."
- Solo founder. Tap → `archive_group` RPC.
- On success: si era el grupo activo, `RootRouter` cambia a otro grupo (o a Profile tab si solo había 1).

`Features/Group/Subscreens/ArchivedGroupsView.swift` (~180 L):
- Lista grupos archivados del founder (`groups.archived_at IS NOT NULL` + `created_by = auth.uid()`).
- Cada item: nombre + "Archivado hace 5 días" + botón "Restaurar".
- Tap restaurar → `unarchive_group` RPC + refrescar `app.groups`.

**`MyProfileView`** (Nivel 0) añade en sección Cuenta: "Grupos archivados (N)" → `ArchivedGroupsView`. Solo si `N > 0`.

**`GroupHomeView`** añade en sección Avanzado (founder-only): "Archivar grupo" → `ArchiveGroupSheet`.

**Acceptance Pass 4:**
- Founder puede archivar grupo + verlo en papelera + restaurarlo.
- Otros admins NO ven la opción de archivar.
- Member normal NO ve la opción.

### Pass 5 · Governance builder UI (deferred decision) (TBD)

**Objetivo:** custom governance, no solo presets.

**Decisión:** este pass requiere su propio spec porque toca una superficie compleja (7-level precedence, scope vs target, condition shapes — ver `Plans/Active/Governance.md`). Diferir.

Lo único que entra en Nivel 1 Pass 5 es: **mover `GovernanceView` a una subscreen de `GroupHomeView` con título "Reglas del grupo"** (cosmético — el contenido sigue siendo presets). El builder granular vive en su propio spec futuro.

### Pass 6 · GroupSwitcher chrome polish (1 sesión)

**Objetivo:** diferenciar tap-para-detalle vs tap-para-cambiar-grupo.

**Cambios:**

| Archivo | Acción |
|---|---|
| `Features/Home/HomeView.swift` (chrome del header) | Tap-en-nombre-del-grupo → `GroupHomeView` (cambio de gesto principal). Long-press → `GroupSwitcherSheet`. Affordance visual: pequeño chevron-down a la derecha del nombre indica "tap para abrir grupo, mantén presionado para cambiar". |
| `GroupSwitcherSheet.swift` | Sin cambios funcionales. |
| Add `Features/Shell/Tabs/GroupTab.swift`? | **NO**. Decidido: NO agregar tab dedicado al grupo. El header + GroupHomeView es suficiente. Agregar tab inflaría el shell. |

**Acceptance Pass 6:**
- Tap-suave abre `GroupHomeView` (no la lista).
- Long-press de 0.5s abre `GroupSwitcherSheet` con haptic feedback.
- Visual indicador (chevron) presente.

## Arquitectura — diagrama Nivel 1 después de las 6 pasadas

```
ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/
├── GroupHomeCoordinator.swift                  (NEW Pass 1, ~120 L)
├── GroupActivityCoordinator.swift              (NEW Pass 3, ~70 L)
├── Views/
│   └── GroupHomeView.swift                     (NEW Pass 1, ~280 L)
└── Subscreens/
    ├── EditGroupIdentitySheet.swift            (NEW Pass 2)
    ├── ModulesPickerView.swift                 (NEW Pass 2)
    ├── GroupCurrencyPickerView.swift           (NEW Pass 2)
    ├── GroupTimezonePickerView.swift           (NEW Pass 2 — refactor compartido con Nivel 0)
    ├── RegenerateInviteCodeSheet.swift         (NEW Pass 2)
    ├── GroupActivityView.swift                 (NEW Pass 3)
    ├── ArchiveGroupSheet.swift                 (NEW Pass 4)
    ├── ArchivedGroupsView.swift                (NEW Pass 4 — vive en Profile/ por scope cross-group del founder)
    ├── GovernanceView.swift                    (MOVED Pass 1 from Features/Groups/Settings/)
    └── RulePresetsView.swift                   (MOVED Pass 1 from Features/Groups/Settings/)

ios/Packages/RuulCore/Sources/RuulCore/Repositories/
├── GroupsRepository.swift                      (extended Pass 2)
└── GroupActivityRepository.swift               (NEW Pass 3)

# Files DELETED in Pass 1:
# - Features/Groups/Switcher/GroupInfoSheet.swift
# - Features/Groups/Settings/GroupSettingsSheet.swift

# Files KEPT (navigation, not content):
# - Features/Groups/Switcher/GroupSwitcherSheet.swift
```

## Wireframe consolidado de `GroupHomeView` post-Pass 6

```
┌─────────────────────────────────────────┐
│  ⟵                                ✏️    │
│                                          │
│         ╭────────────╮                   │
│         │   AVATAR   │                   │
│         ╰────────────╯                   │
│         Cenas de los jueves              │
│         8 miembros                       │
│         🔗 K3X9-Q2VB        [Compartir] │
│                                          │
├─ Configuración ─────────────────────────┤  Pass 1+2
│  ✏️  Nombre y foto                   →  │
│  💱  Moneda                  MXN     →  │
│  🕐  Zona horaria   America/MX       →  │
│  🧩  Módulos              3 activos  →  │
│  📜  Reglas del grupo                →  │  → GovernanceView
│                                          │
├─ Comunidad ─────────────────────────────┤  Pass 1
│  👥  Miembros                       8 → │  → MembersView (existente, refactor menor)
│  📅  Actividad del grupo            →   │  → GroupActivityView (Pass 3)
│                                          │
├─ Avanzado ──────────────────────────────┤  Pass 2 + 4 + 6
│  🔄  Rotar código de invitación     →   │
│  📦  Archivar grupo (founder)       →   │  Pass 4
│  🚪  Salir del grupo                    │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **`GroupInfoSheet` y `GroupSettingsSheet` mueren.** Su contenido vive en `GroupHomeView` directamente. La proliferación de sheets era anti-patrón.
2. **`GroupSwitcherSheet` sobrevive** como pura navegación (lista de grupos para cambiar contexto). No mezcla contenido con navegación.
3. **No se crea un tab dedicado al grupo.** El shell ya tiene 5 tabs; agregar uno por nivel inflaría. Tap-en-header es entry suficiente.
4. **Activity feed del grupo es solo lectura.** No se editan ni borran atoms.
5. **Archivar es founder-only en V1.** El BE permite a otros admins per RLS, pero la decisión humana es: la papelera es del fundador. Otros admins ven "Salir del grupo" pero no "Archivar".
6. **Custom governance builder se difiere a un spec posterior.** Pass 5 solo mueve la vista existente. El builder granular toca demasiada superficie para fusionarse aquí.
7. **`TimezonePicker` se refactoriza a `RuulUI/Patterns/`** porque ya lo usa Nivel 0 (`TimezonePickerView` de `Features/Profile/Subscreens/`). DRY.
8. **"Mis grupos" en `MyProfileView`** (Nivel 0 update lateral) se vuelve un nav row simple a un `GroupListView` o reusa `GroupSwitcherSheet` modal — decisión final en plan.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Mover `GovernanceSettingsView` rompe import paths | `git grep` antes; un find/replace cuidadoso |
| `set_group_module` puede fallar por dependencias sin satisfacer | UI debe validar `GroupModule.dependencies` antes de mostrar el toggle como enabled; bloquear con tooltip |
| Cambiar `currency` no recalcula fines existentes (`fines.amount` está en MXN siempre?) | Confirmar schema antes de Pass 2; si fines tienen amount + currency_at_creation, OK. Si no, agregar warning |
| Realtime channel para activity feed puede ser caro | Pass 3 default sin realtime; pull on appear + refreshable. Realtime se agrega Pass 3.5 si demanda lo justifica |
| El founder no entiende diferencia archive vs leave | Texto explícito en sheets: "Archivar = papelera tuya; Salir = el grupo sigue sin ti" |
| `GroupHomeView` puede crecer demasiado | Si pasa 350 L, dividir en `GroupHomeHeader` + `GroupHomeSections` views. Bound objetivo: <300 L |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `GroupHomeCoordinatorTests`: carga group + modules + member count en una llamada. `GroupHomeViewSnapshotTests`: 3 estados (admin / member / founder). |
| 2 | `GroupsRepositoryTests`: rename / updateCurrency / updateTimezone persisten. `ModulesPickerViewTests`: bloquea toggle si dependencias no satisfechas |
| 3 | `GroupActivityRepositoryTests`: 6 kinds en respuesta. View muestra correctly grouped por día |
| 4 | `ArchiveGroupSheetTests`: solo founder ve botón. `ArchivedGroupsViewTests`: lista solo grupos del founder |
| 6 | `HomeViewChromeTests`: tap-corto vs long-press resuelven a destinos distintos |

## Out of scope

- **Custom governance builder** (Pass 5 dedicated spec future)
- **Bulk invites post-creation** (separate spec)
- **Custom roles UI** (`Group.roles` jsonb mutable but no spec yet)
- **Module dependency resolver UI** (Pass 2 valida pero no orquesta resolución; el power-user moves manuales)
- **Group health / analytics dashboard** (Layer 17 — futuro)
- **Group templates marketplace** (futuro post-V2)

## Done When

- 6 pasadas mergeadas a `main`.
- `GroupHomeView` es el único home del grupo. `GroupInfoSheet` y `GroupSettingsSheet` no existen.
- Tap-corto en nombre del grupo abre `GroupHomeView`. Long-press abre `GroupSwitcherSheet`.
- Toda mutación de `groups` que el BE permite es reachable desde la UI.
- Activity feed muestra los 6 tipos de group system_events.
- Founder puede archivar y restaurar grupos.
- Build clean en Xcode 16+.
- Demo en simulator: rename grupo, rotar código, toggle 3 módulos, archivar grupo, restaurar.

## Cobertura del plan inicial

Recomiendo cubrir **Pass 1 + Pass 2 en el primer commit** (igual cadencia que Nivel 0): es la separación estructural + el wire-up de los campos ya disponibles. Pass 3-6 cada uno como plan separado conforme avancemos.
