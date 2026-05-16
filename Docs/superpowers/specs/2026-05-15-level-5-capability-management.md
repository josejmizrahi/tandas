# Nivel 5 — Capability: gaps + management UI

**Fecha:** 2026-05-15
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `HierarchyReference.md` §3 — Capabilities universales
**Migraciones base:** `00078` (resource_capabilities), `00101` (build_resource_from_draft), `00165` (capabilities catalog seed), `00181` (member_capability_overrides), `00191` (write-lock catalog), `00192` (capability atoms)
**Specs hermanas:** Niveles 0-3 shipped.

## Problema

Nivel 5 vive en dos tablas:
- `capabilities` (catalog frozen — 28 capabilities, mig 00165)
- `resource_capabilities` (`enabled`, `config jsonb`, per-resource)

El BE ofrece:
- `ResourceCapabilityRepository` con `list`, `enable`, `disable`, `updateConfig` (todos en el protocol).
- `build_resource_from_draft` que seedea capabilities en bulk con configs.
- Catalog hardcoded en cliente (`CapabilityCatalog.v1`) con dependencies + status + enabled_resource_types.
- `member_capability_overrides` (mig 00181) para excepciones tipo "David fuera de rotativa".

El FE expone una sliver:

1. **`EnableCapabilitySheet`** solo enable (lista las **inactivas**). Una vez encendida una capability, **no hay forma de apagarla desde la UI**. El repo soporta disable pero nadie llama.

2. **Configs son inmutables post-creación.** El wizard (paso 3) recolecta `rsvp.deadline`, `voting.quorumPercent`, `rotation.order`, etc. Después de crear el resource, el usuario no puede editar ninguno de esos valores. Resultado: si pones deadline mal, está mal para siempre.

3. **Sin warnings de dependencies/conflicts en Resource Detail.** El wizard auto-resuelve silenciosamente. Si en Detail se pudiera disable RSVP, no avisaría que rompe check_in.

4. **`member_capability_overrides` sin UI.** La tabla está implementada (mig 00181) con casos canónicos (`excluded`, `priority_high`, `exempt`) pero el FE no la lee ni la escribe.

5. **Section views faltantes:** Voting (display de configs + tally), Ledger (configuración del fondo), Assignment, Appeal. Cuando la capability está enabled pero no hay section view, el usuario solo ve el ícono "activado" sin poder interactuar.

6. **`memberCapabilityOverridden` atom** se emite (mig 00181 trigger) pero no aparece en feed de actividad.

## Objetivo

Cerrar las 3 lagunas más visibles:

- **Disable + config edit desde Resource Detail.** Tap "Capabilities" en `SettingsSectionView` → muestra ENABLED + INACTIVE; tap enabled → opciones "Editar configuración" + "Desactivar"; tap inactive → enable como hoy.
- **Dependency warnings.** Al intentar desactivar una capability que es dependencia (rsvp → check_in), bloqueador con explicación. Al activar una que requiere otra, auto-enable de la cadena (o bloqueo con CTA).
- **Per-capability config editor genérico** reusando `BuilderFieldRenderer` (que ya renderiza los mismos campos en el wizard).

Pass 3+ (out of scope aquí): section views faltantes (Voting/Ledger/Appeal), member overrides UI.

## Approach — 4 pasadas, Pass 1+2 en este plan

### Pass 1 · `ManageCapabilitiesSheet` (rebrand de `EnableCapabilitySheet`) + config editor

**Cambios:**

| Archivo | Acción | Notas |
|---|---|---|
| `Features/Resources/Detail/EnableCapabilitySheet.swift` | **Rename → `ManageCapabilitiesSheet.swift`** | Lista enabled + inactive en dos secciones |
| `Features/Resources/Detail/EditCapabilityConfigSheet.swift` | **NEW** (~200 L) | Editor genérico — toma `CapabilityBlock` + actual config jsonb → renderiza con `BuilderFieldRenderer` |
| `Features/Resources/Detail/Sections/SettingsSectionView.swift` | **Modify** | "Activar / desactivar capabilities" → "Manejar capabilities". Tap abre `ManageCapabilitiesSheet` |
| `Features/Resources/Detail/Adapters/EventDetailCoordinator.swift` | **Modify** | Wire `disable(_:)` + `updateConfig(_:)` callbacks |

**Flujo:**
```
SettingsSection → tap "Manejar capabilities"
  ↓
ManageCapabilitiesSheet
  ┌─ Activas ────────────────────┐
  │ RSVP             ⋯           │  → tap ⋯ → [Editar config] / [Desactivar]
  │ Check-in         ⋯           │
  │ Ledger           ⋯           │
  └─────────────────────────────┘
  ┌─ Disponibles ────────────────┐
  │ Voting           [Activar]   │  → tap activar → si needs config → EditCapabilityConfigSheet → enable
  │ Rotation         [Activar]   │
  └─────────────────────────────┘
```

### Pass 2 · Dependency warnings + auto-cascade

| Archivo | Acción |
|---|---|
| `RuulCore/Capabilities/CapabilityDependencyResolver.swift` | **NEW** (~80 L). Pure logic: `func dependentsOf(capability:in:enabledSet)` returns blocks that would break if this one is disabled; `func dependenciesOf(capability:)` returns required upstream blocks |
| `ManageCapabilitiesSheet.swift` | **Modify** | At disable-tap, call `dependentsOf` — if non-empty, present `DisableBlockingAlert` listing what would break. Tap "Disable all" → disable cascade. Tap cancel → no-op |
| `EnableCapabilitySheet`-flow (Pass 1's rebrand) | **Modify** | At enable-tap, if `dependenciesOf` non-empty AND some are off, present "Esta capability requiere RSVP" → "Activar también" CTA |

### Pass 3 · Member overrides UI (deferred)

`MemberCapabilityOverridesRepository` + per-member override sheet. Out of scope here; standalone spec.

### Pass 4 · Section views faltantes (deferred)

`VotingSectionView`, `LedgerSectionView`, `AssignmentSectionView`, `AppealSectionView`. Out of scope here; standalone spec.

## Wireframe `EditCapabilityConfigSheet`

```
┌─────────────────────────────────────────┐
│  Cancelar          RSVP         Guardar │
│  ─────────────────────────────────────  │
│                                          │
│  Fecha límite                            │
│  ┌─────────────────────────────────┐    │
│  │ Mañana 6:00 PM             ▼   │    │
│  └─────────────────────────────────┘    │
│                                          │
│  Permitir respuesta "Tal vez"            │
│  ┌─ off                  ──○────────┐   │
│                                          │
│  Esperar lista                           │
│  ┌─ off                  ──○────────┐   │
│                                          │
└─────────────────────────────────────────┘
```

Renderizado dinámicamente desde `CapabilityBlock.requiredFields + optionalFields` via `BuilderFieldRenderer`. **Cero código nuevo por capability**.

## Decisiones explícitas

1. **`BuilderFieldRenderer` se reusa** — el catalog de field types (dateTime, integer, multiPicker, etc.) ya cubre todos los configs conocidos. Si un nuevo config requiere un field type nuevo, se agrega al renderer (1 lugar).

2. **Disable es siempre opt-in con alerta** — no auto-cascade silencioso. Si rsvp tiene dependents, mostrar `[Desactivar todas]` / `[Cancelar]` con lista visible.

3. **Catalog se queda hardcoded client-side** (`CapabilityCatalog.v1`) por ahora. Mig 00191 hace catalog write-locked en BE, así que sync server→client es un nice-to-have, no bloqueador.

4. **`memberCapabilityOverridden` atom NO se expone en Pass 1-2.** Se difiere hasta tener UI de overrides (Pass 3).

5. **Section views faltantes** (voting/ledger/etc.) NO se crean aquí. Cada uno merece spec dedicado con UX por capability.

6. **Pass 2's auto-enable cascade** es opcional CTA, no implícito. Si activas check_in y rsvp está off, se ve alerta "check_in requiere RSVP — ¿activar ambas?".

## Riesgos

| Riesgo | Mitigación |
|---|---|
| `BuilderFieldRenderer` puede no cubrir todos los configs jsonb | Audit `optionalFields/requiredFields` de los 28 capabilities; si falta un type, agregar al renderer (no scope creep — es 1 file) |
| Disable de capability que tiene atoms (RSVPs ya emitidos) | BE no borra los atoms — quedan en historial. UI debe avisar "Las respuestas previas se conservan en actividad" |
| Cascade disable accidental | Alerta con lista visible + texto destructivo. Tap accidental tiene 2 confirmaciones |
| Wizard step 3 ya hace algo similar — código duplicado | Pass 1 puede extraer un `CapabilityConfigForm` view compartido entre wizard y `EditCapabilityConfigSheet` |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `ManageCapabilitiesSheet`: 3 estados (no caps / mixed / all enabled). `EditCapabilityConfigSheet`: round-trip — load config, edit, save, reload muestra cambio. |
| 2 | `CapabilityDependencyResolver`: rsvp disabled → check_in is dependent. `ManageCapabilitiesSheet`: tap disable rsvp con check_in on → alert visible. |

## Out of scope (futuros specs)

- Pass 3 — `MemberCapabilityOverridesSheet` desde `MemberDetailView` (excluded / exempt / priority overrides)
- Pass 4 — Section views: Voting tally, Ledger config, Assignment current, Appeal status
- Realtime sync de capability catalog (server seed → client)
- Capability discovery / docs (link a "qué hace check_in?" tooltip)
- Module-level enable/disable (Layer 6 — modules abstraction)
- Audit visibility de `capabilityToggled` + `capabilityConfigUpdated` atoms en activity feed

## Done When

- 7 tasks committed (4 Pass 1 + 3 Pass 2).
- `ManageCapabilitiesSheet` lista enabled + inactive, ambos manipulables.
- `EditCapabilityConfigSheet` permite editar todos los configs jsonb post-creación.
- Disable bloqueable con alerta cuando hay dependents activos.
- Enable con CTA "Activar también" cuando faltan dependencies.
- Build clean.

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit** (~7 tasks). Pass 3 + Pass 4 cada uno como plan dedicado posterior.
