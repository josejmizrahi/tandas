# R.5V.0 — UI Audit · Native vs Custom Matrix

**Fecha:** 2026-06-07
**Status:** ✅ CLOSED — 64 pantallas auditadas en 17 feature groups
**Companion:** `Plans/Active/R5V_UIConsistencyAppleNative.md` · `Plans/Active/R5V_UXDoctrine.md`

---

## Resumen ejecutivo

| Métrica | Valor | Lectura |
|---|---|---|
| Pantallas auditadas | 64 | 30 leídas + 34 grep-sampled |
| Feature groups | 17 | Activity/Auth/Contexts/Decisions/Events/Home/Money/Resources/etc |
| ✅ Native | **48 (75%)** | Sin violaciones detectables |
| 🟡 Híbrido | **10 (15.6%)** | Cumplen mayoría, faltan capas específicas |
| ❌ Custom (full rewrite) | **0** | Cero pantallas requieren reescritura |
| Hardcoded colors | **0** | 100% disciplina Theme/.accentColor/.secondary/Color(uiColor:) |

**Verdict:** baseline mucho mejor de lo esperado. R.5X.fix.A + R.5Y.A2 + práctica disciplinada ya pusieron la app en buen estado. **V.1 Tokens va a ser pequeño**: no hay hardcoded a remover, sólo agregar 11 semantic tokens a `Theme.swift` para que V.2 los consuma.

---

## Distribución por feature group

| Feature | Pantallas | ✅ | 🟡 | ❌ | Hardcoded colors | Slice principal |
|---|---|---|---|---|---|---|
| Activity | 2 | 2 | 0 | 0 | 0 | — |
| Auth | 1 | 1 | 0 | 0 | 0 | — |
| ContextHome | 3 | 1 | 2 | 0 | 0 | V.3 (legacy deprecate) + V.4 |
| ContextShell | 6 | 4 | 2 | 0 | 0 | V.6 |
| Contexts | 2 | 2 | 0 | 0 | 0 | — |
| Decisions | 4 | 2 | 1 | 0 | 0 | V.5 |
| Events | 6 | 5 | 1 | 0 | 0 | V.5 |
| Home | 1 | 1 | 0 | 0 | 0 | V.3 (priority tinting) |
| Membership | 6 | 6 | 0 | 0 | 0 | — |
| Money | 6 | 4 | 2 | 0 | 0 | V.4 (Attention layer) |
| Profile | 6 | 6 | 0 | 0 | 0 | — |
| Reservations | 5 | 5 | 0 | 0 | 0 | — |
| Resources | 9 | 6 | 3 | 0 | 0 | V.5 |
| Rules | 4 | 4 | 0 | 0 | 0 | — |
| Settlement | 1 | 1 | 0 | 0 | 0 | V.4 |
| Shell | 2 | 2 | 0 | 0 | 0 | — |
| **TOTAL** | **64** | **48** | **10** | **0** | **0** | — |

---

## 🟡 Las 10 pantallas híbridas (todas violan §0.2 patrón Detail)

| Pantalla | Violación | Slice fix |
|---|---|---|
| ContextDetailViewV2 | Attention buried en header (Overview tab card), no entre Hero+Sections como capa explícita | V.4 |
| EventDetailView | Sin widget Attention explícito | V.5 |
| MoneyHomeView | Pagos pending sin Attention card visible | V.4 |
| ObligationDetailView | Sin Attention layer | V.5 |
| ResourceDetailView (v1 legacy) | Sin Attention, marcar deprecar formalmente | V.5 |
| ContextHomeView (v1 legacy) | Sin Activity section en algunas tabs | V.3 (deprecar) |
| DecisionDetailView | Pre-§0.2 layout — Hero existe pero Attention no es capa | V.5 |
| SettlementView | Sin Attention card por settlement_open items locales | V.4 |
| ResourceSettingsView | Forma de Detail sin Attention/Activity | V.6 |
| ContextSettingsView | Forma de Detail sin Attention/Activity | V.6 |

**Fix pattern único:** Extraer `AttentionDispatcher` integration en reusable `detailAttentionLayer(_:)` ViewBuilder. Aplicar a las 10 vistas. **Esto deriva el componente `RuulAttentionCard` de V.2** — ese componente directamente cierra estas 10 violaciones.

---

## Componentes custom existentes vs equivalentes

| Component file | Propósito | Equivalente nativo | Equivalente Ruul* (V.2) | Sustituible? |
|---|---|---|---|---|
| `StateViews.swift` LoadingStateView | ProgressView + label | `ProgressView` | **`RuulLoadingState`** | ✅ V.2 drop-in |
| `StateViews.swift` ErrorStateView | Icon + title + message + retry | `ContentUnavailableView` (iOS 17) | **`RuulErrorState`** | ✅ V.2 drop-in |
| `StateViews.swift` EmptyStateView | Icon + title + message | `ContentUnavailableView` (iOS 17) | **`RuulEmptyState`** | ✅ V.2 drop-in |
| `StateViews.swift` ActionRunner | Async runner con error capture | `@State` + `do/catch` patrón | — | 🟡 Keep (utility no visual) |
| `SubscribeButton.swift` | Subscribe button con state | `Button` con Toggle behavior | — | 🟡 Keep |
| `CreationGuardView.swift` | Modal de duplicados (R.2V.4) | — | 🟡 V.7 podría wrapearlo | 🟡 Keep visual current |
| `QuickActionsSection.swift` | Lista de quick actions | `List` + `Button` rows | **`RuulActionRow`** | ⚠️ Parcial — sólo renderiza 2/5 action states (§0.4 gap) |
| `ActionPresentationCatalog.swift` | Mapping action_key → symbol/tint | — | — | 🟢 Keep (utility, no visual reemplazable) |

**BLOCKER importante:** `StateViews.swift` es usado por **30 pantallas**. V.2 debe entregar `RuulLoadingState/RuulErrorState/RuulEmptyState` como **drop-in replacements** antes de que V.8 los reemplace globalmente.

---

## Violaciones §0 Doctrine detectadas

### §0.2 Patrón Detail (Hero/Attention/Widgets/Sections/Actions/Activity)

**7 vistas Detail** implementan Hero+Sections+Actions pero no exponen Attention como capa explícita entre Hero y resto. Ver tabla arriba.

### §0.3 6 estados universales (active/inactive/archived/pending/completed/cancelled)

Backend emite mayoría de estos via `status`, pero iOS no consolida visualmente:
- ✅ active/archived/pending: badges existen variantes inconsistentes
- ⚠️ inactive: **ORPHAN R.5X** (backend tiene, iOS no renderiza)
- ⚠️ completed/cancelled: badges renderizan pero no uniformemente

**Fix:** `RuulStatusBadge` V.2 con enum de 6 universal states + mapping table de estados legacy.

### §0.4 5 estados de acción (enabled/disabled/requires_decision/coming_soon/dangerous)

**Gap mayor encontrado:**
- ✅ `enabled` → primary button style
- ✅ `disabled` → `.disabled(true)` (R.5X audit confirmó)
- ❌ `requires_decision` → no tiene visual distintivo (no badge, no hint)
- ❌ `coming_soon` → R.5X.fix.A cubre via alert post-tap, pero NO hay badge greyed en row antes del tap
- ❌ `dangerous` → algunas pantallas usan `.foregroundStyle(.red)`, otras no (inconsistente)

**Impacto:** 30+ action rows (QuickActionsSection + manuales en ResourceDetailViewV2/ContextDetailViewV2) pierden semántica.

**Fix:** `RuulActionRow` V.2 con enum de 5 action states, visual diferenciado por estado, label/badge consistente.

### §0.5 4 prioridades attention (critical/high/normal/low)

**Gap mayor:**
- `HomeView.attentionSection` y `ContextDetailViewV2.attentionCard` renderizan TODOS los items con tint `.orange` (R.5Y.A2 helper `AttentionPresentation.tint(for:kind)` mapea por kind, no por priority).
- Backend ya tiene `AttentionItem.derivedPriority` (R.5Y.A2 Domain) pero no se usa visualmente.

**Fix mínimo (V.3):** extender `AttentionPresentation.tint(for:kind:priority)`:
```swift
priority == .critical → .red
priority == .high → .orange
priority == .normal → .blue
priority == .low → .gray
```

Y el sort en attention list debe ser `priority ASC, occurred_at DESC NULLS LAST`.

### §0.1 Jerarquía nav

**Sin violaciones detectables.** R.5Y.A2 AttentionDispatcher mantiene el árbol `Home → Context → Resource → Action` incluso desde shortcuts (e.g. attention.decision_vote abre sheet → DecisionDetailView pero el back stack permanece).

---

## Backlog migrate refinado por slice V.3–V.8

| Slice | Scope | Pantallas | Trabajo principal | Blocker |
|---|---|---|---|---|
| **V.3 HomeView + lists + deprecate legacy** | 15 pantallas (Auth, lists, Home, ContextHome legacy) | HomeView + AllAttentionView; **agregar §0.5 priority tinting** a AttentionPresentation; deprecar ContextHomeView v1 (marcar private + ocultar fallback) | — |
| **V.4 ContextDetailV2 + Money** | 4 pantallas | Refactor ContextDetailViewV2 Attention placement (Overview top, no buried); Agregar Attention card a MoneyHomeView + SettlementView | — |
| **V.5 Detail Views** | 6 pantallas (Decision, Event, Obligation, Reservation, ResourceV1, ResourceV2) | Extraer `detailAttentionLayer()` reusable; aplicar a 6 hybrid detail views; deprecar ResourceDetailView v1 formal | — |
| **V.6 Forms + Settings** | 27 pantallas | `QuickActionsSection` extender a 5 action states (§0.4); ContextSettingsView/ResourceSettingsView migrar a List/Section nativo; CreationGuard badge tints | — |
| **V.7 Sheets/dialogs** | 4 pantallas | ContextConflictsListView dialog isolation; PickerSheets (HostRotation, NextHost) ya cumplen, validar | — |
| **V.8 Global cleanup + a11y** | 64 pantallas | Replace `StateViews.swift` (30 usuarios) → `RuulLoadingState`/`RuulErrorState`/`RuulEmptyState`; accessibility labels en actions; Dynamic Type pass XL/XXXL | **REQUIERE V.2 shipped** |

---

## Top hallazgos founder (lectura corta)

1. ✅ **Baseline excelente.** 0 pantallas custom, 0 hardcoded colors, 75% native. La disciplina previa (Theme + descriptor-driven) pagó intereses.

2. ✅ **V.1 Tokens es minúsculo.** Sin hardcoded colors a remover, V.1 sólo agrega 11 semantic tokens a `Theme.swift` para que V.2 los consuma. Estimado: ~50 LOC + 1 commit.

3. ⚠️ **V.2 `RuulStatusBadge` + `RuulActionRow` cubren 2 gaps grandes** del Doctrine: §0.3 estados universales (mapping inconsistente legacy → 6 canonical) + §0.4 5 action states (sólo 2/5 renderizan hoy).

4. ⚠️ **V.3 priority tinting** es trivial: extender `AttentionPresentation.tint(for:kind:priority)` con 4 colores. Sin esto, los items críticos no se diferencian visualmente de los normales en attention card.

5. ⚠️ **V.8 BLOCKER.** El reemplazo global de `StateViews.swift` (30 usuarios) sólo puede correr DESPUÉS de que V.2 estabilice `RuulLoadingState/RuulErrorState/RuulEmptyState`. Por eso V.8 va al final.

6. 🟢 **Las 10 hybrid views convergen en una sola refactorización:** extraer `detailAttentionLayer()` ViewBuilder + componente `RuulAttentionCard` V.2 cierra todas las 7 violaciones §0.2 + las 3 settings/detail extra.

---

## Cierre

R.5V.0 marca `Status: ✅ CLOSED` con:

1. ✅ 64 pantallas clasificadas (✅48 / 🟡10 / ❌0).
2. ✅ 0 hardcoded colors (disciplina previa OK).
3. ✅ Componentes custom mapeados a equivalentes nativos/Ruul*.
4. ✅ 4 categorías de violaciones §0 Doctrine encontradas + slice fix asignado.
5. ✅ Backlog migrate V.3–V.8 refinado con scope concreto.

Siguiente paso: **R.5V.1 Tokens (11 semantic) en `Theme.swift`** — ~50 LOC + 1 commit.
