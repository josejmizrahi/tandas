# FASE 1 — Modal + Empty State Inventory (input para C/D)

**Status**: Read-only audit, written 2026-05-19.
**Scope**: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/` —
todas las superficies usuario-finales.
**Doctrine source**: `~/Library/.../memory/fase1_native_refactor_doctrine.md`
+ `Plans/Active/Fase1NativeAudit.md` §3-§4.

**Purpose**:
- Sección 1 alimenta Deliverable D (Human Layer Rules) — copy template
  + 8+ ejemplos Ruul que el founder puede aprobar / redirigir antes de
  ejecutar Wave 2 PR #11 (`EmptyStateView` → `ContentUnavailableView`).
- Sección 2 alimenta Deliverable C (Component Map §4 + §11) —
  decision tree concreto con call-sites reales para clasificar cada
  modal del codebase como `sheet` / `fullScreenCover` / `alert` /
  `confirmationDialog`.

**Constraints respetadas**:
- Read-only — ningún `.swift` tocado.
- Copy proposals respetan doctrina "reduce ansiedad / una sola acción
  sugerida / lenguaje humano sin ontología".
- Modal refactor calls flagged contra la política app-wide "todo es
  fullScreenCover" (`RuulSheet.swift:5` 2026-05-15) que la doctrina FASE 1
  explícitamente revierte para forms multi-step.

---

## TL;DR

- **22 empty states** distribuidos en 12 features. 11 usan el primitive
  canónico `EmptyStateView` (consistente), 11 inline (inconsistente
  visual — algunos solo Text, otros VStack con icono propio).
- **0 usos de `ContentUnavailableView`** (iOS 17+ native). El primitive
  no existe todavía en el codebase. Wave 2 PR #11 introduce el cambio.
- **~70 puntos de presentación modal** (sheet + fullScreenCover combinados).
  Política app-wide actual: TODO es `fullScreenCover` (incluso vía
  `ruulSheet()` que internamente llama `fullScreenCover`). Doctrina FASE 1
  contradice esto: forms multi-step DEBEN ser `.sheet` con
  `.presentationDetents([.medium, .large])`.
- **9 alerts** + **4 confirmationDialogs**. Mixed usage: 2 alerts deberían
  ser confirmationDialog (destructive: bulk-resolve, finalizar votación),
  resto OK.
- **No hay `RuulSheet`/`RuulFullScreenCover` directos** — todo el código
  usa el wrapper `.ruulSheet(...)` o el primitive nativo. Refactor de la
  política se centraliza en `RuulUI/Primitives/RuulSheet.swift:1-29`.

---

## Sección 1 — Empty States Inventory

### 1.1 Empties usando `EmptyStateView` (canónico actual)

| file:line | área | symbol | title (current) | message (current) | action | proposal (Apple-native) |
|---|---|---|---|---|---|---|
| `Feed/Views/MyFeedView.swift:155-162` | Feed cross-grupo | `calendar.badge.clock` | "Todo tranquilo por ahora" | "Cuando alguno de tus grupos cree un evento, vas a verlo acá junto con los demás." | — | **KEEP TONO.** Title OK ("tranquilo" = calma, doctrina-aligned). Message OK pero recortar: "Cuando un grupo cree un evento, aparecerá aquí." `ContentUnavailableView("Todo tranquilo", systemImage: "calendar", description: Text("Cuando un grupo cree un evento, aparecerá aquí."))` |
| `Activity/Views/ActivityView.swift:221-230` | Activity timeline grupo | `clock.arrow.circlepath` | "Sin actividad todavía" | "Cuando pasen cosas en el grupo —eventos, RSVPs, multas, votaciones— aparecerán acá." | — | **REWRITE message.** Lista "eventos/RSVPs/multas/votaciones" expone ontología y agrega ansiedad de configuración. → "Cuando algo pase en el grupo, lo verás aquí." |
| `Fines/Views/ReviewProposedFinesView.swift:92-99` | Admin review fines | `checkmark.circle.fill` | "Nada que revisar" | "No hay multas propuestas pendientes para este evento." | — | **KEEP.** Title celebrativo + message factual. `.tint(.green)` opcional en el symbol para reforzar "all clear". |
| `Fines/Views/MyFinesView.swift:58-67` | Mis multas (perfil) | `checkmark.circle.fill` | "Sin multas" | "No tienes multas en este momento. Sigue así." | — | **KEEP.** "Sigue así" es exactamente el tono que la doctrina pide (calma, no ansiedad). |
| `Votes/Views/OpenVotesListView.swift:30-37` | Votaciones abiertas | `hand.raised` | "No hay votos abiertos" | "Cuando el grupo abra una votación, aparecerá acá." | Optional "Crear votación" (gated) | **KEEP**, pero CTA gated debería desaparecer en V1 — doctrina pide UNA acción sugerida, no condicional. Remover `BetaFeatureFlags.current.showGenericVoteCreation` branch (POST-V1). |
| `Fines/Sheets/AddManualFineSheet.swift:27-31` | Sheet — picker miembros | `person.2` | "Sin otros miembros" | "No hay otros miembros en este grupo." | — | **DEMOTE a inline message.** Empty hero size dentro de un sheet small detent rompe layout. → footer text en la `Section { } footer: { Text("Aún no hay otros miembros en el grupo.") }` |
| `Members/Views/MembersAdminView.swift:72-78` | Admin miembros | `person.2` | "Sin miembros activos" | "Invita miembros con el botón "+" para empezar." | — | **REWRITE acción.** Empty-state debe llevar CTA primaria, no apuntar a un "+" que el usuario tiene que encontrar. → `ContentUnavailableView { Label("Aún no hay miembros", systemImage: "person.2") } description: { Text("Invita a alguien para arrancar.") } actions: { Button("Invitar miembros") { onInviteTap() } }` |
| `Members/Views/MembersListView.swift:22-28` | Lista pública miembros | `person.2` | "Sin miembros activos" | "Cuando alguien se una al grupo, aparecerá aquí." | — | **KEEP.** Read-only context; sin CTA porque el lector no puede invitar. |
| `Inbox/Views/ActionInboxView.swift:55-61` | Inbox (pendientes) | `tray` | "Sin pendientes" | "No hay multas, apelaciones ni RSVPs por atender. Todo al corriente." | — | **REWRITE message.** Lista ontológica ("multas/apelaciones/RSVPs") agrega ansiedad. → "Todo al corriente." (solo). El "Sin pendientes" + "Todo al corriente" es la frase canónica calma-pero-positiva. |
| `Inbox/Views/InboxView.swift:237-242` | Inbox filtrada categoria | `tray` | "Sin pendientes" | "No hay acciones en esta categoria." | — | **REWRITE message.** Apple-native: "Aquí aparecen los pendientes de esta categoría." (descriptivo del futuro, no del presente vacío). |
| `Inbox/Views/InboxView.swift:330-335` | Inbox resueltas | `checkmark.circle` | "Sin resueltas" | "Cuando completes acciones aparecerán aquí." | — | **KEEP.** Read-only history view, sin CTA correcto. |
| `Resources/Past/PastResourcesView.swift:32-38` | Historial eventos | `clock` | "Sin eventos pasados" | "Aquí aparecen los eventos cerrados o cancelados." | — | **KEEP.** Descriptivo del propósito, ningún ruido ontológico. |
| `Resources/Sheets/Money/EventLedgerSheet.swift:128-133` | Sheet — ledger fondo/evento | `tray` | "Sin movimientos" | "Registra el primer gasto o aportación de esta \(vocabulario)." | — | **MOVE TO SECTION FOOTER.** Empty con CTA implícita dentro de un sheet → Section footer + el `Button("Registrar gasto")` ya está abajo. Empty hero compite con el CTA. |
| `Rules/EditRulesView.swift:140-146` | Editar reglas | `list.bullet.clipboard` | "Sin reglas" | "Este grupo no tiene reglas configuradas." | — | **REWRITE message.** "configuradas" = SaaS. → "Este grupo aún no tiene reglas." + acción "Crear regla". |
| `Resources/Sheets/HostActions/EventRulesSheet.swift:50-57` | Reglas de un evento | `list.bullet.clipboard` | "Sin reglas aplicables" | (admin) "Agrega reglas que sólo apliquen a este recurso. Las del grupo seguirán aplicando." / (no admin) "Sólo el anfitrión o un fundador pueden crear reglas específicas para este recurso." | — | **BAN "recurso".** Doctrina: "resource" no debe aparecer en UI. → "Sin reglas para este evento." / admin: "Agrega reglas que solo apliquen a este evento. Las del grupo siguen aplicando." / non-admin: "Solo el anfitrión o un fundador puede crear reglas para este evento." |

### 1.2 Empties inline (no usan `EmptyStateView`) — inconsistentes

| file:line | área | shape actual | copy actual | proposal |
|---|---|---|---|---|
| `Profile/Subscreens/DevicesView.swift:86` | Lista de dispositivos | solo `Text` plano dentro de `ScrollView.refreshable` | "Aún no hay dispositivos registrados." | **PROMOTE.** Esta pantalla merece `ContentUnavailableView("Sin dispositivos", systemImage: "iphone", description: Text("Vas a verlos aquí cuando uses Ruul desde otro dispositivo."))`. |
| `Profile/Subscreens/MyTimelineView.swift:76` | Mi historia | solo `Text` plano dentro de `ScrollView.refreshable` | "Aún no hay actividad" | **PROMOTE.** → `ContentUnavailableView("Aún sin historia", systemImage: "clock", description: Text("Cuando hagas algo en un grupo, aparecerá aquí."))`. |
| `Rules/RuleComposerView.swift:199` | Menu picker dentro composer | `Text` dentro de `Menu` | "No hay momentos compatibles con este recurso" | **KEEP CONTEXT, REWRITE.** Menu disabled state es válido inline. → "No hay momentos disponibles." (sin "recurso"). |
| `Rules/RuleDetailView.swift:126` | Detalle regla — section vacía | solo `Text` caption | "Sin consecuencias configuradas." | **MOVE TO SECTION FOOTER.** `Section { } footer: { Text("Sin consecuencias.") }` (recorta "configuradas" = SaaS). |
| `Votes/Sheets/CreateMemberRemovalSheet.swift:111` | Menu picker miembros | `Text` dentro de `Menu` | "Sin miembros disponibles" | **KEEP** — disabled menu state, idiom nativo. |
| `Rules/RulesView.swift:265-289` | Empty hero rules | VStack a mano (icon + 2 texts + Button) | "Sin reglas" + "Este grupo aún no tiene reglas configuradas. Elige un patrón y se activa con dos taps." + opcional CTA "Crear primera regla" | **MIGRATE a `ContentUnavailableView`.** → `ContentUnavailableView { Label("Sin reglas", systemImage: "list.bullet.clipboard") } description: { Text("Elige un patrón y se activa al toque.") } actions: { Button("Ver patrones") { showGallery = true } }`. Recortar "configuradas / con dos taps" (SaaS-y). |
| `Votes/Detail/Bodies/GenericVoteBody.swift:20` | Cuerpo votación sin descripción | `Text` plano tertiary | "Sin detalles adicionales." | **KEEP**. Field-level empty, no warranted hero. |
| `Resources/Create/PostCreateIntentScreen.swift:136-151` | Post-create sin intents | VStack a mano (sparkles + 2 texts) | "Nada que configurar todavía." + "Lo que necesites lo activas desde el recurso." | **REWRITE + MIGRATE.** "configurar / recurso" = SaaS+ontología. → `ContentUnavailableView { Label("Listo por ahora", systemImage: "checkmark.circle") } description: { Text("Lo que necesites lo agregas después.") }`. |
| `Resources/Views/SlotDetailView.swift:42` | Detalle cupo sin asignación | `Text` plano en `LabeledContent`-like row | "Sin titular" | **KEEP.** Field-level, idiom correcto. |
| `Fines/Views/MyFinesView.swift:117` (hero) | All-clear hero (NO empty — todas pagadas) | HStack icon + 2 texts | "Todo al corriente" + ("No tienes multas pendientes." / "Pagaste todas tus multas.") | **KEEP** — este es un *positive state*, no empty. Doctrina lo respalda (celebrate calma sin ruido). |
| `Fines/Views/MyFinesView.swift:196` | Filtered empty (scope != all) | `Text` callout | "Sin multas en este periodo." | **KEEP** — filtered subset state, no warranted hero. |
| `Resources/ResourcePickerField.swift:77` | Picker recursos vacío | inline HStack icon+text | "Aún no hay recursos en este grupo." | **REWRITE.** Doctrina ban "recurso". → "Aún no hay nada que vincular." |
| `Resources/MemberPickerField.swift:79` | Picker miembros disabled | inline HStack icon+text | "Sin miembros disponibles" | **KEEP** — picker disabled idiom. |
| `Resources/Sheets/Money/AddLedgerEntrySheet.swift:131` | Picker counterparty vacío | inline `Text` caption | "No hay otros miembros en este grupo." | **KEEP** — field-level. |
| `Resources/Detail/Sheets/LinkResourcePickerSheet.swift:183-203` | Picker vincular | VStack a mano (Circle + icon + 2 texts) | "Nada que vincular aún" + "Crea un espacio, asset o fondo en el grupo y vuelve para vincularlo a este evento." | **REWRITE + MIGRATE.** Doctrina ban "espacio/asset/fondo/recurso". → `ContentUnavailableView { Label("Nada que vincular", systemImage: "link") } description: { Text("Cuando el grupo tenga más cosas, las puedes vincular aquí.") }`. |
| `Resources/Detail/Sections/LocationEditorSheet.swift:73,77` | Section footer location editor | `Text` caption en `Section.footer` | (con query) "Sin coordenadas todavía. Elige una sugerencia para que abra Maps al tappear." / (sin query) "Empieza a escribir el nombre del lugar o una dirección." | **KEEP** — `Section.footer` es el idiom nativo correcto. Lenguaje OK. |
| `Resources/Detail/Subviews/RSVPAvatarStrip.swift:116-128` | Strip avatars vacíos | HStack icon+text | "Sin confirmaciones aún" | **KEEP** — inline-strip empty, hero no aplica. |
| `Resources/Create/Steps/ResourceVariantPicker.swift:54-66` | Picker variantes vacío | VStack a mano (icon + text) | "Por ahora no hay variantes para \(label)." | **MIGRATE a `ContentUnavailableView`.** Recortar a "Sin variantes disponibles para \(label)." — "por ahora" agrega ansiedad temporal. |
| `Profile/Views/MyLedgerView.swift:277-300` | Mis movimientos | VStack a mano (Circle 80pt + icon + 2 texts) | "Aún sin movimientos" + "Cuando registres una aportación, gasto o pago, aparecerá aquí con su grupo." | **MIGRATE a `ContentUnavailableView`.** Title OK. Message → "Tu actividad de dinero aparece aquí." (más corto, sin lista). |

### 1.3 Plantilla canónica `ContentUnavailableView` (Deliverable D)

#### Tres partes obligatorias

```swift
ContentUnavailableView {
    Label("<Title — qué falta, calmado>", systemImage: "<SF Symbol>")
} description: {
    Text("<Una frase — qué aparecerá aquí o cómo arranca>")
} actions: {
    Button("<Una acción sugerida>") { ... }  // omitir si no hay CTA natural
}
```

#### Reglas de copy (doctrine-locked)

1. **Title**: 1-3 palabras. Estado, no problema. ✅ "Sin multas" / "Todo
   tranquilo" / "Aún sin historia". ❌ "No tienes multas pendientes
   todavía" / "Ups, esta pantalla está vacía".
2. **Description**: 1 frase corta. Describe el *futuro* (cuándo aparecerá
   contenido) o el *propósito* del lugar (qué vive aquí). Nunca lista
   ontológica ("eventos/multas/RSVPs/votaciones"). Nunca instrucciones de
   navegación ("toca el botón "+" arriba a la derecha").
3. **Action**: máximo UNA. Solo si hay una acción natural sin
   pre-condiciones. Si el lector no puede actuar (no es admin / es read-
   only), OMITIR action — no degradar a 2 CTAs ni a texto explicativo.
4. **Symbol**: SF Symbol semantically aligned. `tray` = pendientes /
   inbox. `clock` = histórico / pasado. `calendar` = eventos /
   futuro. `checkmark.circle` = positive empty (all done). `person.2` =
   miembros. `list.bullet.clipboard` = reglas. `hand.raised` = votos.
   `link` = vinculación. `iphone` = dispositivos.
5. **Tone**: calma, no entusiasmo SaaS. NO `!`, NO emojis, NO "vamos!
   crea el primero!".
6. **Lenguaje banneado** (per Fase1NativeAudit.md §6): capability,
   module, projection, atom, resource_type, trigger, consequence,
   resource (como noun), governance, ledger.

#### 8 ejemplos canónicos Ruul (founder-approvable)

```swift
// 1. Fondo vacío (sin movimientos)
ContentUnavailableView {
    Label("Aún sin movimientos", systemImage: "tray")
} description: {
    Text("Los gastos y aportaciones aparecen aquí.")
} actions: {
    Button("Registrar movimiento") { openAddSheet() }
}

// 2. Eventos vacíos (futuro del grupo)
ContentUnavailableView {
    Label("Sin eventos", systemImage: "calendar")
} description: {
    Text("Cuando alguien proponga uno, aparecerá aquí.")
} actions: {
    Button("Crear evento") { openCreateSheet() }
}

// 3. Members vacío (admin context)
ContentUnavailableView {
    Label("Aún no hay miembros", systemImage: "person.2")
} description: {
    Text("Invita a alguien para arrancar.")
} actions: {
    Button("Invitar miembros") { onInviteTap() }
}

// 4. Fines vacíos (positive — "todo al corriente")
ContentUnavailableView {
    Label("Sin multas", systemImage: "checkmark.circle")
} description: {
    Text("Estás al corriente.")
}
// no action — celebrar, no empujar

// 5. Votos vacíos (read-only feed)
ContentUnavailableView {
    Label("No hay votos abiertos", systemImage: "hand.raised")
} description: {
    Text("Cuando el grupo abra una votación, la verás aquí.")
}
// V1: no CTA — vote creation es POST-V1 (vote_scope_freeze)

// 6. Rules vacías (admin context con gallery CTA)
ContentUnavailableView {
    Label("Sin reglas", systemImage: "list.bullet.clipboard")
} description: {
    Text("Elige un patrón y se activa al toque.")
} actions: {
    Button("Ver patrones") { showGallery = true }
}

// 7. Inbox vacío (positive — "al día")
ContentUnavailableView {
    Label("Sin pendientes", systemImage: "tray")
} description: {
    Text("Todo al corriente.")
}
// no action

// 8. Activity feed vacío (timeline read-only)
ContentUnavailableView {
    Label("Sin actividad todavía", systemImage: "clock.arrow.circlepath")
} description: {
    Text("Cuando pase algo en el grupo, lo verás aquí.")
}
// no action
```

#### Variantes especiales

- **Filtered subset vacío** (e.g. "Sin multas en este periodo") →
  inline `Text` callout *encima* de los chips, NO hero. El hero solo
  para empty global.
- **Field-level empty** (e.g. "Sin titular" en SlotDetailView) → `Text`
  plano en el row, NO hero.
- **Picker/menu empty** → `Text` dentro del `Menu { }`, NO hero. Usuario
  está mid-tap, ContentUnavailableView confunde el flow.
- **Section vacía dentro de un detail** (e.g. "Sin consecuencias" en
  RuleDetailView) → `Section { ... } footer: { Text("...") }` o
  `Section { Text("Sin <X>") }` con `.foregroundStyle(.secondary)`.
- **Error state** → `ContentUnavailableView(label:description:actions:)`
  con action = `Button("Reintentar")`. (Cubre `ErrorStateView`).

---

## Sección 2 — Modal Pattern Inventory

### 2.1 Anti-patrón estructural (centralizado)

**`RuulUI/Primitives/RuulSheet.swift:1-29`** define la política
app-wide 2026-05-15: el wrapper `.ruulSheet(...)` internamente llama
`.fullScreenCover(...)`. Comentario en código:

> "App-wide policy 2026-05-15: every modal route is a full takeover with
> an explicit close affordance, not a partial-overlap sheet."

**FASE 1 doctrina contradice esto explícitamente**. Component Map §4
(`Plans/Active/Fase1ComponentMap.md`) requiere `.sheet(...)
.presentationDetents([.medium, .large])` para forms multi-step. El
refactor:

1. Cambiar `RuulSheet.swift` para que `ruulSheet(...)` llame
   `.sheet(isPresented:)` con detents por defecto, NO `fullScreenCover`.
2. Auditar los ~30 call sites de `.fullScreenCover(...)` directos en
   `RootShellSheets.swift` / `ProfileTab.swift` / EventDetail — convertir
   los que sean forms a `.sheet`. Solo retener `fullScreenCover` para
   los takeovers reales (scanner, OTP, onboarding step, RuleComposer
   full-edit).
3. Beneficio doctrina-aligned: presentación parcial es CALMA — sheet
   compacto te deja ver el contexto detrás. fullScreenCover es agresivo,
   más cercano a "modal in modal" si se anida.

### 2.2 Inventario completo `.sheet` (15 call sites)

| file:line | purpose | doctrine-correct primitive | refactor |
|---|---|---|---|
| `Claims/PendingClaimsView.swift:52` | Sub-sheet review claim individual | `.sheet` con `.presentationDetents([.large])` | KEEP. Es un sheet legítimo (nested forms — claim review). |
| `Shell/RootShell.swift:98` | Pending claims auto-surface | `.fullScreenCover` (es un takeover de start-up) | OK as-is — flow de auth post-OTP. |
| `Shell/RootShell.swift:101` | Claim review from deeplink | `.sheet([.large])` | KEEP. |
| `Shell/Tabs/ProfileTab.swift:110` | ShareSheet (export CSV) | `.sheet` — `UIActivityViewController` siempre es sheet en iOS | KEEP. |
| `Resources/Create/PostCreateIntentScreen.swift:451` | Sub-sheet destinations (form picker) | `.sheet([.medium, .large])` | KEEP — es sheet correcto. |
| `Onboarding/Founder/Views/InviteMembersView.swift:58` | ContactPicker (CNContactPickerViewController) | `.sheet` — sistema lo presenta como sheet | KEEP. |
| `Members/Views/InviteMembersFromGroupView.swift:42` | AddPlaceholder form | `.sheet([.medium, .large])` | KEEP — form. |
| `Members/Views/InviteMembersFromGroupView.swift:51` | Contact picker (system) | `.sheet` — system-owned | KEEP. |
| `Resources/Detail/Adapters/EventDetailHost.swift:201` | RotationParticipants management | `.sheet([.large])` | KEEP — multi-step picker form. |
| `Resources/Detail/Adapters/EventDetailHost.swift:207` | LocationEditorSheet | `.sheet([.large])` | KEEP — form. |
| `Rules/RuleComposerView.swift:83` | UniversalTemplateGallerySheet | `.sheet([.large])` | KEEP — gallery picker (form-like). |

### 2.3 Inventario `.fullScreenCover` (47 call sites)

#### A. KEEP fullScreenCover — takeovers legítimos (mid-flow / chromeless)

| file:line | purpose | razón keep |
|---|---|---|
| `Shell/RootShellSheets.swift:67` (`.groupHome`) | Group home full UI takeover | Es una "pantalla" lógica, no un form. Cumple Nav §1 doctrina. |
| `Shell/RootShellSheets.swift:92` (`.createCover`) | Resource creation flow multi-step | Mid-flow takeover post-onboarding. |
| `Shell/RootShellSheets.swift:102` (event detail), `:118` (resource detail), `:251` (fine detail), `:272` (vote detail) | Detail screens "from anywhere" | Cumplen política V2 Slice 4: "one entry per destination". Detail = takeover. |
| `Shell/RootShellSheets.swift:134` (scanner) | QR scanner | Chromeless camera takeover por definición. |
| `Onboarding flows` (no listados — `OnboardingScreenTemplate` está fuera del scope per audit §5 keep-list) | Onboarding steps | Doctrina: "Mid-flow takeover (onboarding step, scanner) → fullScreenCover". |
| `Activity/Views/ActivityView.swift:58` (system event detail) | Event detail from activity row | Detail screen — takeover legítimo. |
| `Activity/Views/ActivityView.swift:75` (history filter) | Filter sheet | **REFACTOR → `.sheet([.medium])`** — es un form-picker. |
| `Members/Views/MemberDetailView.swift:80` (roles picker) | Role picker | **REFACTOR → `.sheet([.medium])`** — form selection. |
| `Resources/Views/SlotDetailView.swift:72,75` (assign / swap) | Assignment forms | **REFACTOR → `.sheet([.medium, .large])`** — forms. |
| `Rules/RulesView.swift:137` (composer) | Full rule composer | KEEP — multi-step takeover (Calendar event creation pattern). |
| `Rules/RulesView.swift:150` (gallery) | Template gallery picker | **REFACTOR → `.sheet([.large])`** — picker. |
| `Rules/EditRuleSheet.swift:100` (composer reopen) | Composer from edit | KEEP — composer takeover. |
| `Rules/RuleDetailView.swift:77` (params edit) | Params edit | **REFACTOR → `.sheet([.medium])`** — form. |
| `Rules/EditRulesView.swift:21` (edit rule sheet) | Edit rule form | **REFACTOR → `.sheet([.large])`** — form. |
| `Group/Subscreens/GroupRolesSheet.swift:62` (role editor) | Role editor form | **REFACTOR → `.sheet([.medium, .large])`** — form. |
| `Members/Views/MembersAdminView.swift:50` (propose removal) | Vote creation form | **REFACTOR → `.sheet([.large])`** — form. |
| `Home/HomeView.swift:116` (open resource) | Resource detail | KEEP — detail takeover. |
| `Resources/Detail/Adapters/EventDetailSheets.swift:141` (attendee detail) | Member detail nested | KEEP — detail. |
| `Profile/Views/MyProfileView.swift:402` (legacy wizard) | Resource wizard (legacy / advanced) | KEEP — full wizard takeover. |

#### B. REFACTOR `.fullScreenCover` → `.sheet` con detents (forms / pickers / single-action sheets)

**Todos los siguientes son forms o picker single-step. Doctrina pide
`.sheet` con `.presentationDetents`.** Lista exhaustiva:

| file:line | route | purpose | new primitive | detents |
|---|---|---|---|---|
| `RootShellSheets.swift:25` | `.groupSwitcher` | Group switcher list | `.sheet` | `[.medium, .large]` |
| `RootShellSheets.swift:33` | `.createGroup` | Create group form | `.sheet` | `[.large]` |
| `RootShellSheets.swift:41` | `.joinGroup` | Join group form | `.sheet` | `[.medium]` |
| `RootShellSheets.swift:48` | `.inviteShare` | Invite members | `.sheet` | `[.large]` |
| `RootShellSheets.swift:54` | `.groupRulesSettings` | Rules presets | `.sheet` | `[.large]` |
| `RootShellSheets.swift:79` | `.ruleEdit` | Rule edit | `.sheet` | `[.large]` |
| `RootShellSheets.swift:129` | event edit | Event edit form | `.sheet` | `[.large]` |
| `RootShellSheets.swift:154` | `.createVotePicker` | Vote type picker | `.sheet` | `[.medium]` |
| `RootShellSheets.swift:164` | `.createGeneralProposal` | Proposal form | `.sheet` | `[.large]` |
| `RootShellSheets.swift:193` | `.createRuleChange` | Rule change vote form | `.sheet` | `[.large]` |
| `RootShellSheets.swift:224` | `.createMemberRemoval` | Member removal vote form | `.sheet` | `[.large]` |
| `RootShellSheets.swift:267` | `.past` | Past events list | `.sheet` | `[.large]` |
| `RootShellSheets.swift:420,432` | invite (inner) | Invite | `.sheet` | `[.large]` |
| `RootShellSheets.swift:424` | edit identity | Group identity form | `.sheet` | `[.medium]` |
| `RootShellSheets.swift:428` | rotate code | Rotate code confirm + display | `.sheet` | `[.medium]` |
| `RootShellSheets.swift:436` | leave group confirm | Leave group | **`.confirmationDialog`** | n/a — destructive, no sheet |
| `RootShellSheets.swift:611` | invite (admin wrapper) | Invite | `.sheet` | `[.large]` |
| `ProfileTab.swift:77` | edit profile | Profile form | `.sheet` | `[.large]` |
| `ProfileTab.swift:84` | my fines | Mis multas (read-only list) | `.sheet` | `[.large]` |
| `ProfileTab.swift:103,104` | change phone / email | OTP re-auth flow | KEEP `.fullScreenCover` — multi-step auth takeover |
| `ProfileTab.swift:105` | my timeline | Read-only timeline list | `.sheet` | `[.large]` |
| `ProfileTab.swift:106` | devices | Devices list | `.sheet` | `[.medium, .large]` |
| `ProfileTab.swift:107` | notification preferences | Settings form | `.sheet` | `[.large]` |
| `Resources/ResourceDetailSheet.swift:49,63` (ledger / rules) | Sub-sheets desde resource detail | `.sheet` | `[.large]` |
| `Resources/Detail/Adapters/EventDetailSheets.swift:56-130` (10 ruulSheet calls — share/qr/cancel/remind/close/manualFine/ledger/rules/attendees) | Event sub-sheets | `.sheet` | `[.medium, .large]` cada uno (.medium para share/QR/confirm-style; .large para forms) |
| `Resources/Sheets/Money/EventLedgerSheet.swift:47` (add entry) | Ledger entry form | `.sheet` | `[.medium, .large]` |
| `Resources/Sheets/HostActions/EventRulesSheet.swift:84` (add rule) | Add rule form | `.sheet` | `[.large]` |
| `Resources/Detail/Adapters/EditEventView.swift:47` (cover picker) | Cover picker | `.sheet` | `[.medium]` |
| `Votes/Detail/VoteDetailHost.swift:71,76` (cast / admin) | Vote actions | `.sheet` | `[.medium]` |
| `Fines/Views/FineDetailHost.swift:75,85` (appeal / void) | Fine actions | `.sheet` | `[.large]` (appeal — reason input) / `[.medium]` (void — confirm) |
| `Fines/Views/ReviewProposedFinesView.swift:70` (void) | Void fine | `.sheet` | `[.medium]` |
| `Onboarding/.../InviteMembersView.swift:61` (manual entry) | Manual phone entry form | `.sheet` | `[.medium]` |

#### C. AUDIT_FURTHER (ambigüedad)

| file:line | route | duda |
|---|---|---|
| `Shell/RootShellSheets.swift:54` (`.groupRulesSettings`) | RulePresetsView dentro de cover | ¿Es full management screen o un picker single-action? Leer `RulePresetsView` para decidir entre `.sheet([.large])` y `fullScreenCover` (si tiene NavigationStack interna con varias pantallas) → propenso a fullScreenCover. |
| `Shell/RootShellSheets+Bindings.swift` (helper file) | router bindings | No tiene presentación propia — solo construye bindings. OK. |

### 2.4 Inventario `.alert` (9 call sites)

| file:line | purpose | doctrine-correct primitive | refactor |
|---|---|---|---|
| `Rules/EditRuleSheet.swift:119` "¿Archivar regla?" | Destructive confirm + open vote | **REFACTOR → `.confirmationDialog`** — destructive action. |
| `Inbox/Views/InboxView.swift:113` "¿Marcar las N acciones?" | Destructive bulk-resolve | **REFACTOR → `.confirmationDialog`** — destructive (irreversible). |
| `Votes/Detail/VoteDetailHost.swift:79` "Finalizar votación" | Destructive finalize | **REFACTOR → `.confirmationDialog`** — destructive. |
| `Votes/Detail/VoteDetailHost.swift:87` "Cancelar votación" | Destructive cancel | **REFACTOR → `.confirmationDialog`** — destructive. |
| `Group/Subscreens/GroupRolesSheet.swift:72` "Eliminar este rol" | Destructive role delete | **REFACTOR → `.confirmationDialog`** — destructive. |
| `Members/Views/MembersAdminView.swift:39` "Echar a este miembro" | Destructive kick | **REFACTOR → `.confirmationDialog`** — destructive. |
| `Members/Views/MembersAdminView.swift:45` "No pudimos guardar el cambio" | Error display | **KEEP `.alert`** — error = alert. ✅ |
| `Shell/RootShellSheets.swift:452` "No pudimos archivar" | Error display | **KEEP `.alert`** — error. ✅ |
| `Shell/Tabs/ProfileTab.swift:125` "No pudimos completar la acción" | Error display | **KEEP `.alert`** — error. ✅ |

### 2.5 Inventario `.confirmationDialog` (4 call sites)

| file:line | purpose | doctrine-correct primitive | check |
|---|---|---|---|
| `Shell/RootShellSheets.swift:440` "¿Archivar \(group)?" | Destructive archive group | `.confirmationDialog` ✅ | KEEP — canónico. |
| `Rules/RuleComposerView.swift:250` "Aplanar agrupaciones" | Destructive flatten OR/NOT tree | `.confirmationDialog` ✅ | KEEP. |
| `Profile/Views/MyProfileView.swift:133` "¿Salir de tu cuenta?" | Destructive sign-out | `.confirmationDialog` ✅ | KEEP. |
| `Shell/Tabs/ProfileTab.swift:113` "¿Eliminar tu cuenta?" | Destructive delete account | `.confirmationDialog` ✅ | KEEP. |

### 2.6 Decision Tree canónico (Deliverable C §4 + §11)

```
Tengo que mostrar algo encima de la pantalla actual.
└── ¿Es un mensaje al usuario (no requiere su input estructurado)?
    ├── YES — error / un-recoverable / "se hizo X"
    │   └── .alert("Título corto", isPresented:) { Button("OK") }
    │       Ejemplo: "No pudimos archivar" (RootShellSheets.swift:452)
    │
    └── NO — requiere acción del usuario
        └── ¿Es destructiva o irreversible? (delete, void, finalize,
                                              archive, sign-out, kick,
                                              flatten, bulk-resolve)
            ├── YES → .confirmationDialog(titleVisibility: .visible)
            │        con Button(role: .destructive) + Cancel
            │   Ejemplos:
            │   - "¿Archivar \(group)?" (RootShellSheets.swift:440) ✅
            │   - "¿Eliminar tu cuenta?" (ProfileTab.swift:113) ✅
            │   - Pendiente migrar: kick member, void fine, finalize
            │     vote, archive rule, bulk-resolve inbox
            │
            └── NO — requiere input o navegación
                └── ¿Es un takeover mid-flow inevitable?
                    (scanner, OTP, onboarding step, multi-screen
                     full wizard como RuleComposer)
                    ├── YES → .fullScreenCover(isPresented: / item:)
                    │   Ejemplos KEEP:
                    │   - scanner (RootShellSheets.swift:134)
                    │   - resource creation flow (RootShellSheets.swift:92)
                    │   - rule composer (RulesView.swift:137)
                    │   - change phone/email OTP (ProfileTab.swift:103,104)
                    │
                    └── NO — form / picker / single-step
                        └── .sheet(isPresented: / item:)
                              .presentationDetents([.medium, .large])
                              .presentationDragIndicator(.visible)
                            Ejemplos refactor:
                            - createGroup form → .sheet([.large])
                            - leave group confirm → confirmationDialog
                              (NO sheet — es destructive)
                            - share event sheet → .sheet([.medium])
                            - ledger entry form → .sheet([.medium, .large])
                            - assign slot → .sheet([.medium])
                            - filter sheet → .sheet([.medium])
```

#### Cuándo usar cada detent

- `.medium` solo: confirmaciones cortas, share, QR, picker single-list.
- `[.medium, .large]`: forms que crecen con teclado o tablas largas.
- `[.large]`: forms multi-step inline, listas paginadas, edit screens
  completas.
- `.fraction(0.X)`: evitar — quiebra accessibility (Dynamic Type).

#### Anti-patrones (BAN doctrine-aligned)

1. **No `.fullScreenCover` para forms single-step.** El partial-overlap
   del sheet es la calma del HIG. Política app-wide actual contradice
   doctrina → revertir.
2. **No modal-in-modal stacks.** `RootShellSheets` ya tiene 5+ niveles
   anidados (event detail → eventDetailSheets → manualFineCoordinator →
   AddManualFineSheet → memberPicker). Estructurar por
   `NavigationStack` dentro del sheet en lugar de presentar otro
   sheet/cover.
3. **No `.alert` para destructive.** `.alert` es para *informar*,
   `.confirmationDialog` para *confirmar acción*. Apple usa
   `.confirmationDialog` en Mail (delete email), Notes (delete note),
   Photos (delete photo) — la consistencia es el punto.
4. **No `.alert(role: .destructive)` como atajo.** Mismo principio — la
   *shape* del UI debe ser confirmationDialog (bottom-sheet style en
   iPhone), no centered alert.
5. **No `RuulSheet` wrapper en su forma actual.** `.ruulSheet(...)` =
   `.fullScreenCover(...)` viola doctrina. Refactor: hacer que llame
   `.sheet(...).presentationDetents(...)` o eliminar el wrapper
   completamente y usar el primitive nativo (preferred per
   Fase1SimplificationPlan.md).

---

## Sección 3 — Open questions / AUDIT_FURTHER

1. **Política app-wide 2026-05-15 ("todo es fullScreenCover")**: ¿se
   revoca formalmente como parte de FASE 1 Wave 2? Sin esta decisión
   explícita, refactor de ~30 call sites queda bloqueado por la nota en
   `RuulSheet.swift:5-9`. Doctrina FASE 1 implícitamente la revoca pero
   founder debería aprobarlo de forma explícita.

2. **`RuulSheet` wrapper future**: ¿retain como thin wrapper que llama
   `.sheet(...)`, o eliminar completamente y usar `.sheet` nativo en
   call sites? Per audit §3.A wave 2 PR #9 sugiere eliminar; alinea
   con doctrina "thin wrappers around Apple-native behavior" pero
   también pierde el centralized close-affordance enforcement.

3. **`ModalSheetTemplate`**: 19 call sites lo usan (mayoría sheets del
   event detail). El audit §3.D recomienda DELETE. ¿Migrar antes,
   durante o después de Wave 2 PR #9? Bloquea cualquier refactor de
   detents porque el template fuerza un chrome único.

4. **OTP re-auth flows** (`ChangePhoneFlow` / `ChangeEmailFlow`): son
   multi-step takeovers que justifican `fullScreenCover`. Pero
   `MyTimelineView` / `DevicesView` / `NotificationPreferencesView`
   también usan `fullScreenCover` desde `ProfileTab` y son
   read-only/settings — refactor a `.sheet` directo. Confirm con
   founder que las settings list pages NO son "takeover".

5. **Filtered subset empty UX**: `MyFinesView.swift:196` muestra un
   `Text` callout cuando filtros activos vacían el resultado. ¿Es la
   forma canónica o debería ser un sub-`ContentUnavailableView`
   secundario inline? Sugerencia: callout para subset, Hero para empty
   global. Pendiente de aprobación.

6. **Pre-existente all-clear hero** (`MyFinesView.swift:117`
   "Todo al corriente"): coexiste con un EmptyStateView "Sin multas"
   abajo. ¿Es UX intencional (hero positive cuando alguna vez hubo
   multas, empty silencioso cuando nunca hubo)? Confirmar — la
   distinción es buena pero el código actual lo deja ambiguo.

7. **`EmptyStateView` keep vs delete**: audit §4 dice REPLACE con
   `ContentUnavailableView`. Una vez migrado, el primitive queda
   huérfano. ¿Borrar `RuulUI/Patterns/EmptyStateView.swift` en la
   misma PR o dejar deprecated? Recomendado borrar en PR #11 para
   cumplir doctrina "delete custom UI aggressively".

---

## DoD checklist

- [x] Sección 1 Empty States Inventory — 22 sites tabulados (11
      EmptyStateView + 11 inline)
- [x] Sección 2 Modal Pattern Inventory — 75 sites tabulados
      (15 sheet + 47 fullScreenCover + 9 alert + 4 confirmationDialog)
- [x] Plantilla canónica `ContentUnavailableView` con reglas de copy
      + 8 ejemplos Ruul (fondo, eventos, members, fines, votos,
      rules, inbox, activity feed)
- [x] Decision tree modal con ejemplos concretos del codebase
- [x] Open questions / AUDIT_FURTHER list

**Next**: founder review de copy + política sheets-vs-cover. Tras
aprobación, este doc se cierra y los refactor calls migran a
`Fase1SimplificationPlan.md` (Wave 2 PR #9 "sheets" + PR #11 "empty
states").
