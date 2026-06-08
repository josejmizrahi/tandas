# R.5V — UI Consistency System · Apple Native UI Doctrine

**Fecha:** 2026-06-07
**Status:** 🟡 ACTIVATED — founder firmó orden 2026-06-07
**Bloquea:** Documents V2 (V.0a+V.0+V.1+V.2 son pre-requisito)
**Bloqueado por:** `Plans/Active/R5V_UXDoctrine.md` (V.0a — congela vocabulario antes de auditar UI)
**Companion:** `Plans/Active/PreR6_Roadmap.md`

---

## Objetivo

Unificar la UI de Ruul manteniendo **experiencia Apple-native**. No queremos una app que parezca web dashboard. Queremos una app iOS premium, clara, rápida y familiar.

---

## Regla principal

> **Antes de crear un componente custom, revisar si existe equivalente nativo de Apple.**

## Prioridad

```
1. Native first
2. Descriptor-driven
3. Reusable components
4. Custom only when native no cubre el caso
```

---

## Componentes nativos a usar

`NavigationStack` · `List` · `Section` · `Form` · `toolbar` · `confirmationDialog` · `alert` · `sheet` · `Menu` · `contextMenu` · `swipeActions` · `searchable` · `Picker` · `DatePicker` · `Toggle` · `Stepper` · `ShareLink` · `QuickLook` · `PhotosPicker` · `documentImporter` · `SF Symbols` · `Dynamic Type` · semantic colors · materials.

## Componentes canónicos Ruul (wrappers de nativos, NO reemplazos)

| Componente | Encapsula | Razón de existir |
|---|---|---|
| `RuulScreenHeader` | NavigationStack toolbar + hero | Consistencia de hero entre pantallas detail |
| `RuulHeroCard` | VStack + materials | Encabezados rich de detail views (Resource/Context) |
| `RuulSectionCard` | Section dentro de List/Form | Tarjetas agrupadas con padding/background semánticos |
| `RuulActionRow` | Button/NavigationLink + Label | Filas tappables de detail (action_key + visible + chevron) |
| `RuulStatusBadge` | Text + Capsule + tint | Badges de estado (active/archived/pending/etc) |
| `RuulMetricPill` | HStack icon + value + label | KPIs en metrics cards |
| `RuulEmptyState` | ContentUnavailableView | Estado vacío consistente |
| `RuulErrorState` | ContentUnavailableView + retry | Error con retry button |
| `RuulLoadingState` | ProgressView + label | Loading consistente |
| `RuulAttentionCard` | Card con AttentionDispatcher tap | Attention card en HomeView / ContextDetailV2 |

---

## Reglas visuales

- **Backgrounds:** system / secondary / grouped — NO hardcode.
- **Tint:** semántico (`Color.accentColor`, semantic role tints) — tokens centrales (`Theme.Tint.success/.warning/.danger/.info`).
- **SF Symbols** en TODOS los iconos.
- **Dark mode correcto** en todas las pantallas.
- **Dynamic Type:** `.font(.callout)` etc. semantic, NO `.system(size:)` fijo.
- **Accessibility labels** en actions principales.
- **Loading/progress:** native (`ProgressView`).
- **Empty states:** `ContentUnavailableView` (iOS 17+).
- **Confirmation dialogs:** `confirmationDialog` para decisiones rápidas (≥3 opciones).
- **Sheet:** flows cortos.
- **fullScreenCover:** sólo para creación compleja / wizard.
- **Form:** configuración y creación estructurada.
- **List/Section:** settings, actions, detalles agrupados.

## Anti-reglas

- ❌ NO crear dropdown web custom (use `Menu` / `Picker`).
- ❌ NO crear modal custom si `sheet` nativo basta.
- ❌ NO crear cards con sombra pesada tipo web (usar `materials` + `RoundedRectangle` sutil).
- ❌ NO meter dashboards densos estilo desktop (List/Section, no GridLayouts cargados).
- ❌ NO hardcodear colores por pantalla (tokens en `Theme/`).
- ❌ NO duplicar componentes visuales (extender los Ruul* existentes).
- ❌ NO hacer botones fantasmas (cubre regla R.5W: tampoco labels sin botón real).
- ❌ NO mostrar errores técnicos crudos (R.5X.fix.A cubre — replicar copy "Próximamente").

---

## Sub-slices (V.0 → V.8)

### V.0 Auditoría — qué pantallas se sienten no nativas

Inventariar TODAS las pantallas y marcar:

| Pantalla | Nativo (✅) / Híbrido (🟡) / Custom (❌) | Justificación si custom | Slice migrate |
|---|---|---|---|
| HomeView | 🟡 | Hero + Atención card + Continuar carousel | V.3 |
| ContextDetailViewV2 | 🟡 | Segmented picker + custom cards | V.4 |
| ResourceDetailViewV2 | 🟡 | Hero card + widgets row + sections + actions | V.5 |
| CreateResourceView | 🟡 | Form parcial + custom suggestion rows | V.6 |
| etc. | | | |

V.0 produce `Plans/Reports/R5V_NativeAuditMatrix.md` con todas las pantallas clasificadas + lista de custom components actuales vs equivalente nativo.

### V.1 Tokens mínimos sobre Apple semantic colors (founder scope SIMPLE)

**Founder firma 2026-06-07:** NO hacer 200 tokens. Lista canónica fija de **11 tokens**. Apple resuelve el resto.

| Token | Apple base | Uso |
|---|---|---|
| `Theme.primary` | `Color.accentColor` | tint primario · CTAs · selección |
| `Theme.success` | `.green` | states active/completed positivos |
| `Theme.warning` | `.orange` | conflict warning · pending · archived |
| `Theme.critical` | `.red` | conflict critical · cancelled · dangerous |
| `Theme.info` | `.blue` | información neutral · invitation |
| `Theme.background` | `Color(uiColor: .systemBackground)` | fondo principal |
| `Theme.secondaryBackground` | `Color(uiColor: .secondarySystemBackground)` | fondos de cards |
| `Theme.groupedBackground` | `Color(uiColor: .systemGroupedBackground)` | List grouped style |
| `Theme.primaryText` | `Color.primary` | texto principal |
| `Theme.secondaryText` | `Color.secondary` | subtítulos · captions |
| `Theme.tertiaryText` | `Color(uiColor: .tertiaryLabel)` | metadata · chevrons |

**Anti-reglas:**
- ❌ No agregar `Theme.success500`, `Theme.warning400`, etc. (no scale Tailwind-style)
- ❌ No hex hardcoded (`#FF6600`)
- ❌ No `Color(red: 0.5, green: ...)` literal en views
- ❌ No depender de paleta Sentry/HumanLayer/etc. (semantic Apple-first)

Mantener helpers existentes utilitarios (`Theme.Spacing.xs/.sm/.md/.lg/.xl`, `Theme.cardShape()`, materials) — son rhythm, no colores. V.1 NO los altera.

V.1 produce 1 commit: extender `Theme.swift` con los 11 tokens + remove hardcoded colors de las pantallas (audit V.0 lista cuáles).

### V.2 Componentes canónicos Ruul — cherry-pick 8 primera ola (founder firmado)

**Founder scope (2026-06-07):** primera ola = 8 componentes que impactan inmediatamente Home/Attention/ContextDetail/ResourceDetail/DocumentDetail/DocumentsV2. Segunda ola = 2 más cosméticos, deferred.

**Founder cita literal:** *"agregaría `RuulDetailHero` porque hoy Context/Resource/Document/Decision Detail van a terminar necesitando el mismo encabezado. Ese componente se va a reutilizar muchísimo."*

#### Primera ola (~540 LOC, build verde)

| File | Encapsula | LOC est. | Impacta |
|---|---|---|---|
| **`RuulDetailHero.swift`** | NavigationStack toolbar + icon + title + statusBadge + subtitle + chips | 100 | **Context · Resource · Document · Decision · Event · Actor detail headers** — el más reusado |
| `RuulHeroCard.swift` | VStack + materials hero (para listas/cards de hero) | 100 | Hero secundarios (HomeView greeting, EmptyState rich, etc.) |
| `RuulActionRow.swift` | Button/NavLink + Label + chevron + 5 action states (UX Doctrine §0.4) | 80 | Cualquier row tappable + actions list |
| `RuulStatusBadge.swift` | Capsule + tint semántico + 6 universal states (UX Doctrine §0.3) | 50 | active/inactive/archived/pending/completed/cancelled |
| `RuulEmptyState.swift` | `ContentUnavailableView` wrapper | 40 | Lista vacía consistente |
| `RuulErrorState.swift` | `ContentUnavailableView` + retry button | 50 | Error con retry |
| `RuulLoadingState.swift` | `ProgressView` + label | 30 | Loading consistente |
| `RuulAttentionCard.swift` | Card que delega a AttentionDispatcher (R.5Y.A2) + 4 priorities (§0.5) | 90 | HomeView + ContextDetailV2 |

**Diferencia HeroCard vs DetailHero:**
- `RuulDetailHero` = top de toda `Detail View`. Single source para Context/Resource/Document/Decision/Event/Actor. Reusable masivo.
- `RuulHeroCard` = greeting cards, banners, callouts dentro de scroll (no es el top de la pantalla).

#### Segunda ola (deferred, post-Documents V2)

| File | Razón deferred |
|---|---|
| `RuulMetricPill.swift` | KPIs en metrics — HStack existente cubre |
| `RuulSectionCard.swift` | Section nativo ya cubre |

V.2 ship por commits separados (1 commit por componente) o batch (1 commit). **Cero romper screens existentes** — sólo añadir disponibles para migrate en V.3+.

### V.3 Migrar HomeView + Attention

- HomeView usa `RuulScreenHeader`, `RuulAttentionCard`, `RuulSectionCard` para Continuar / Actividad.
- Tools row queda con `RuulEmptyState` (Próximamente) o List rows con `.disabled(true)`.
- Build verde, smoke device.

### V.4 Migrar ContextDetailViewV2

- 5 tabs siguen con `Picker(.segmented)`.
- attentionCard → `RuulAttentionCard`.
- conflictsCard → `RuulSectionCard` con `RuulStatusBadge`.
- metricsCard → grid de `RuulMetricPill`.
- widgetsRow → `List` horizontal o `ScrollView(.horizontal)` consistente.
- childContexts → carousel con `RuulHeroCard` mini.
- More tab sections → `List` plana con `RuulActionRow`.

### V.5 Migrar ResourceDetailViewV2

- Hero → `RuulHeroCard` con capabilities chips estandarizadas.
- widgetsRow → `RuulSectionCard` + scroll horizontal.
- sectionsCard → `List` plana con `RuulActionRow`.
- actionsCard → grouped `List` por section con `RuulActionRow` (enabled honors `descriptor.actions[].enabled`).
- relationsCard → `RuulSectionCard` con NavigationLinks.
- linkedEvents/Obligations/Decisions → `RuulSectionCard` cada uno.
- conflictsCard → `RuulSectionCard` con `RuulStatusBadge`.
- ResourceActionFormView → migrar a `Form` nativo si no lo es ya.

### V.6 Migrar CreateResourceView + forms

- CreateResourceView, CreateEventView, CreateDecisionView, CreateObligationView, RecordExpenseView, etc → `Form` nativo con `Section`.
- TextField/Picker/Toggle/DatePicker uniform.
- Submit con `toolbar(.confirmationAction)` y Cancel con `toolbar(.cancellationAction)`.
- Location suggestions → MapKit picker o `RuulActionRow` consistent.

### V.7 Migrar sheets/dialogs

- Sheets usan `.presentationDetents([.medium, .large])` cuando aplica.
- Confirmation dialogs (3-kind conflicts, dangerous actions) usan `confirmationDialog` nativo (ya cumple).
- Alerts post-success/error usan `.alert(...)` nativo (ya cumple).
- ResourceActionFormView confirmation/success usan native.

### V.8 Accessibility + Dynamic Type pass

- `.accessibilityLabel` en actions con icon sin texto.
- `.accessibilityHint` para affordances no obvias.
- `Dynamic Type` test con `XL` y `XXXL` (verificar truncation razonable).
- VoiceOver pass en HomeView, ContextDetailV2, ResourceDetailV2.

---

## Acceptance

- ✅ La app se siente iOS nativa.
- ✅ NO se rompe descriptor-driven.
- ✅ NO se rompe AttentionDispatcher.
- ✅ Build verde por slice.
- ✅ Dark mode correcto en todas las pantallas migradas.
- ✅ Dynamic Type razonable en HomeView / ContextDetailV2 / ResourceDetailV2.
- ✅ Estados loading/empty/error consistentes vía Ruul* components.
- ✅ Todas las acciones críticas usan native `confirmationDialog`.
- ✅ Todas las listas principales usan `List/Section` salvo caso justificado.

---

## Orden integrado FIRMADO (founder 2026-06-07)

```
✅ R.5X.fix.A/B/C
✅ R.5Y.A1/A2
⏳ R.5V.0a UX Doctrine    — congela vocabulario (Hero/Attention/Widgets/Sections/Actions/Activity, action states, conflict severities, etc)
⏳ R.5V.0   UI Audit       — qué pantallas se sienten no nativas (matriz)
⏳ R.5V.1   Design Tokens   — semantic colors + Theme.swift extension
⏳ R.5V.2   Componentes 7   — cherry-pick HeroCard/ActionRow/StatusBadge/Empty/Error/Loading/AttentionCard
⏳ Documents V2 — nace usando Ruul* desde el inicio
⏳ Resource Subtype Picker
⏳ R.5V.3–V.8  — Migrar pantallas + a11y (paralelo a R.6 con regla "R.6 backend NO se bloquea por UI")
⏳ R.5W.fix.* — 3 P1 cosméticos
⏳ R.6 Rule Engine 2.0
```

**Regla de paralelización (founder firmado):** R.6 backend (Rule Engine / Policies / Violations / Automations) puede avanzar mientras V.3–V.8 corren en paralelo sobre la capa visual. **R.6 NO se bloquea por UI.**

V.2 segunda ola (RuulScreenHeader/RuulMetricPill/RuulSectionCard) viene después de V.3–V.8 si surge necesidad.

---

## Estado por sub-slice

| Slice | Status | Notes |
|---|---|---|
| V.0a UX Doctrine | ✅ FROZEN 2026-06-07 | `Plans/Active/R5V_UXDoctrine.md` firmado founder |
| V.0 UI Audit | ⏳ | Doc-only, produce `Plans/Reports/R5V_NativeAuditMatrix.md` |
| V.1 Tokens | ⏳ | Extender `Theme.swift` + remove hardcoded colors |
| V.2 Componentes (7) | ⏳ | Cherry-pick founder firmado |
| V.3 HomeView | ⏳ | Paralelo a R.6 OK |
| V.4 ContextDetailViewV2 | ⏳ | Paralelo a R.6 OK |
| V.5 ResourceDetailViewV2 | ⏳ | Paralelo a R.6 OK |
| V.6 CreateResourceView + forms | ⏳ | Paralelo a R.6 OK |
| V.7 Sheets/dialogs | ⏳ | Paralelo a R.6 OK |
| V.8 Accessibility + Dynamic Type | ⏳ | Paralelo a R.6 OK |

---

## Founder firmas (2026-06-07)

| Q | Decisión |
|---|---|
| 1. ¿V.0+V.1+V.2 antes de Documents V2? | ✅ SÍ — Design System → Componentes → Documents V2 |
| 2. ¿Scope V.2? | ✅ Cherry-pick 7 primero (HeroCard/ActionRow/StatusBadge/Empty/Error/Loading/AttentionCard); 3 deferred |
| 3. ¿V.3–V.8 paralelo a R.6? | ✅ SÍ con regla: R.6 backend NO se bloquea por UI |
| 4. ¿UX Doctrine previo? | ✅ NUEVO V.0a — `R5V_UXDoctrine.md` congela vocabulario antes de auditar UI |
