# FASE 1 — Human Layer Rules (Deliverable D)

**Status**: Plan-only, written 2026-05-19. Pairs with `Fase1NativeAudit.md`,
`Fase1SimplificationPlan.md`, `Fase1ComponentMap.md`.

**Purpose**: Rules that govern how Ruul *talks to* and *behaves with* a
human user. The simplification plan (B) deals with structure; the
component map (C) deals with shape; this deliverable deals with
**language, flow choice, and emotional register**.

Founder framing (verbatim from doctrine memory):

> "Ruul should feel like a first-party Apple app." Human, calm,
> spatially clear, native, predictable, accessible, fast, legible,
> trustworthy. Closer to Reminders / Calendar / Wallet / Home / Notes /
> Health / Invites / Find My — NOT Notion / Linear / Airtable / crypto
> dashboards / admin panels.
>
> "The ontology is infrastructure. The UI must feel human and native."
>
> "Delete custom UI aggressively. Prefer native over clever. Prefer
> calm over expressive. Prefer clarity over uniqueness."

---

## 1. Glossary: banned → allowed vocabulary

Every UI-rendered string, label, title, navigation destination, sheet
title, button caption, picker option, alert title, and accessibility
label must obey this glossary. Internal types, file names, database
columns, and code comments may use the banned terms — that's the
"ontology is infrastructure" half. The "human" half is what the user
sees.

### Primary banned terms

| Banned (in UI copy) | Allowed (in UI copy) | Notes |
|---|---|---|
| capability | permiso / función / cosa que puede hacer | When listing what a member can do: "permisos". When describing what a resource can do: "funciones" or "cosas que puede hacer". |
| module | función / característica | "Activar módulo de multas" → "Activar multas". |
| projection | vista / resumen | Never surface "projection" to the user. |
| atom | evento / movimiento / actividad | Use "movimiento" in money context, "actividad" elsewhere. |
| resource_type / resourceType | tipo (in context: evento, fondo, posición…) | Avoid the abstract noun. Surface the concrete type: "Crear evento", "Crear fondo". |
| resource | the concrete noun (evento, fondo, espacio, derecho…) | Never write "Crear nuevo recurso". Surface the concrete options or rename. |
| trigger | cuándo / al pasar X | "Trigger: event_close" → "Cuándo: cuando termina el evento". |
| consequence | qué pasa / resultado | "Consequence: issue_fine" → "Qué pasa: se emite una multa". |
| rule shape | tipo de regla | If user-facing at all. |
| governance hierarchy | quién decide / decisiones del grupo | Never "jerarquía de gobernanza". |
| governance | decisiones / acuerdos | "Editar gobierno" → "Editar acuerdos" o "Decisiones del grupo". |
| ledger | movimientos / historial / dinero | "Mi ledger" → "Mis movimientos". |
| ontology | n/a — never appears in UI | Internal-only concept. |
| primitive | n/a | Internal-only. |
| schema | n/a | Internal-only. |
| RLS / RPC / migration | n/a | Never user-facing. |

### Secondary terms (codebase noise worth a UI sweep)

| Banned (in UI copy) | Allowed (in UI copy) | Notes |
|---|---|---|
| owner / hosteador | anfitrión / quien organiza | "Hosteas tú" is colloquial but fine. "Owner" is enterprise. |
| participant | miembro / asistente | Context-dependent. |
| permission level (as label) | quién puede | "Permission level: anyMember" → "Quién puede: cualquier miembro". |
| referenceId / referenceID / reference id | n/a | Internal. |
| polymorphic | n/a | Internal. |
| outbox | (nothing user-facing) | Internal. |
| RSVP (literal) | "¿Vas?" / "Voy" / "No voy" / "Tal vez" | Apple Invites uses "Voy / No voy / Tal vez". |
| invite_code | código del grupo | "Código de invitación" is fine but "código" alone is shorter. |
| commit / merge / push | n/a | Never. |
| feed (as label) | actividad / movimientos / inicio | Context-dependent. "Feed" is web/social-media jargon. |
| flow / flujo (as label) | (nothing — drop entirely) | "El flujo 2 cubre…" is internal. User never sees a flow name. |

### "Human" register markers

| Avoid | Prefer |
|---|---|
| Loading… (period or no period? mixed) | Cargando | Apple Spanish uses "Cargando" without ellipsis. |
| Confirm (as button) | Confirmar / OK | "Confirm" is enterprise. |
| Edit (as button) | Editar | — |
| Done | Listo | Apple's standard "Listo" for confirmation actions. |
| Submit | Enviar / Guardar | "Submit" is form-engine. |
| Cancel | Cancelar | — |
| Delete | Eliminar / Borrar / Cancelar (event) | Prefer the verb that matches the noun. |
| Yes / No | Sí / No | Spanish punctuation. |
| Error | (don't title-case "Error") | Native iOS uses sentence-case. |
| Required | Obligatorio | — |
| Optional | Opcional / "(opcional)" inline | — |
| Settings | Ajustes | — |

### Title case vs sentence case

Apple Spanish (es-MX, es-ES) uses **sentence case** for almost
everything: nav titles, button labels, alert titles, section headers.
The only title-case exceptions are: brand names (ruul, Apple), proper
nouns (cities, named groups), and the wordmark itself.

| Wrong (title case) | Right (sentence case) |
|---|---|
| "Mi Perfil" | "Mi perfil" |
| "Crear Evento" | "Crear evento" |
| "Editar Grupo" | "Editar grupo" |
| "Próximos Eventos" | "Próximos eventos" |
| "Gobierno" | "Decisiones del grupo" (also renamed per glossary above) |

### Uppercase headers

**Banned**. The footnote token currently renders section headers as
`PRÓXIMOS / INVITADOS / EN VIVO` (Apple Sports stat-readout style).
Apple's own apps (Settings, Reminders, Calendar, Wallet, Mail) DO NOT
uppercase section headers. `Section("Title") { }` renders sentence-case
naturally, which is what we want.

Drop `.textCase(.uppercase)` everywhere. Let `Section` provide its
native chrome.

---

## 2. Decision tables: which native primitive for which intent?

### 2.1 Sheet vs Tab vs Menu vs Alert vs ConfirmationDialog

| User intent | Use | Why |
|---|---|---|
| Switch between primary app areas | **Tab** (`TabView`) | Persistent affordance; iOS canon for shell navigation. |
| Switch between sub-views inside a detail screen | **Picker(.segmented)** at top of the screen | Lightweight, doesn't add a second TabView. |
| Quick edit / create / select that the user might want to abandon | **Sheet** (`.sheet`, `.medium`/`.large` detent) | Swipe-down dismiss is safe; underlying context stays visible. |
| Required step the user MUST complete (or explicitly cancel) | **FullScreenCover** | No accidental dismiss; full focus. |
| Reveal 2-5 secondary actions on a button | **Menu** (`Menu { Button() }`) | Apple's canonical "more actions" affordance. |
| Confirm a destructive action with 2-3 choices | **ConfirmationDialog** | Native red destructive role; native cancel anchor. |
| Block on an error or required notice (1-2 buttons) | **Alert** | Modal, blocking, acknowledged. |
| Inform of a non-blocking success | **Nothing** (silent success — the new state IS the confirmation) | No toast. The row appears. The toggle is on. Move on. |
| Inform of a non-blocking warning | **Section footer text** (inline) | `Section { rows } footer: { Text("Quedan 30 min antes del checkin") }`. |
| Inform of a non-blocking error tied to a single field | **Section footer text** (inline, red) | Inline error in the Form. |
| Suggest the user do something | **ContentUnavailableView** action button | Where the empty state lives. |

### 2.2 FullScreenCover vs Sheet — concrete rules

| Flow | Cover | Reason |
|---|---|---|
| Onboarding (founder + invited) | **FullScreenCover** | Cold-start takeover. |
| Resource Wizard (create event / fund) | **Sheet** with `.large` detent + `NavigationStack` inside | User may want to refer to underlying group context. (Reverses the 2026-05-15 policy — pending founder confirm, see B §7 Q6.) |
| Edit member / edit event / edit fund | **Sheet** with `.medium` then `.large` | Short edit; underlying context useful. |
| OTP / verification step | **FullScreenCover** | Required step, no escape. |
| Photo / cover picker | **Sheet** with `.medium` | Picker UX. |
| Confirm RSVP (with consequences message) | **Sheet** with `.medium` | Quick action. |
| Confirm appeal / cast vote | **Sheet** with `.medium` | Quick action. |
| Camera (QR scanner) | **FullScreenCover** | Hardware focus; takeover. |
| Sharing (system share sheet) | **Native ShareLink** (not our presentation) | Apple-provided. |
| Group switcher | **Sheet** with `.medium` | Quick action; user may want to compare groups. |

### 2.3 NavigationLink vs Button { sheet } vs Button { fullScreenCover }

| Action | Use | Why |
|---|---|---|
| Read-mostly drill-in (view details) | `NavigationLink` | Push retains the parent visible above the title; native back swipe. |
| Quick edit / commit dialog | `Button { sheet }` | Returns to exact same scroll position; less commit ceremony. |
| Multi-step wizard | `Button { fullScreenCover }` containing a `NavigationStack` | Wizard owns the nav stack. |
| Destructive confirmation | `Button { confirmationDialog }` | One-tap → 2-button modal. |
| External link | `Link(destination:)` or `ShareLink` | Native handling. |
| Pure action (no UI to show) | `Button { Task { await ... } }` | No navigation. |

### 2.4 Alert vs ConfirmationDialog

| Situation | Use | Buttons |
|---|---|---|
| One-button acknowledgment ("Tu sesión expiró") | `.alert` | OK |
| Two-button decision, no destructive option ("¿Reintentar?") | `.alert` or `.confirmationDialog` (Apple's docs prefer dialog) | Reintentar / Cancelar |
| Destructive confirmation ("¿Cancelar el evento?") | `.confirmationDialog` | "Cancelar evento" (role: .destructive) + "No cancelar" (role: .cancel) |
| Choose among 3-4 similar options after tapping one button | `.confirmationDialog` | All buttons + Cancel |
| Async error that requires retry+cancel | `.alert` with `presenting:` typed error | Reintentar + Cancelar |
| Async error that the user just needs to know about | `.alert` | OK |

### 2.5 Banner-inline vs Alert vs Silent success

| Outcome | Treatment |
|---|---|
| Save succeeded (event created, RSVP set, profile updated) | **Silent** — the new row appears, the sheet dismisses, the toggle is on. No notification. |
| Save failed (validation, network) | **`.alert`** if blocking the flow; **Section footer text** (red) if it's a single-field issue inside a Form. |
| Background sync completed (new events available) | **Pull-to-refresh** spinner + auto-refresh. No toast. |
| Long-running task started (e.g. uploading photo) | **Inline `ProgressView`** in the row that's updating, plus disabling that row's controls. |
| Long-running task completed (photo uploaded) | **Silent** — the photo replaces the placeholder. |
| Critical error (auth expired, account banned) | **`.alert`** with "Cerrar sesión" / "Cancelar". |
| Warning user should see but not block on (e.g. "Quedan 30 min antes del checkin") | **Section footer text** in the relevant Section. |
| Notification (push, inbox) | **Native iOS notification + Inbox row** (NOT an in-app toast). |

The rule: **if you find yourself wanting a toast, you don't need a
toast.** Either show the consequence (success), block (alert), or
inform inline (footer).

---

## 3. Empty state template

Every empty state in Ruul follows a 3-part template. Use
`ContentUnavailableView` (iOS 17+) — see Component Map §8.

```
[ icon ]
[ TITLE — what this area IS, 1 short clause ]
[ DESCRIPTION — 1-2 short sentences that REDUCE ANXIETY ]
[ ONE CTA — a single, suggested next action ]
```

### Rules

1. **The title says what this area IS, not what's missing.**
   - ❌ "Aún no hay eventos."
   - ✅ "Sin eventos esta semana."
   - ✅ "Empieza a usar tu fondo."

2. **The description REDUCES anxiety.** Make it normal that this is
   empty. The user is not behind. Nothing is broken.
   - ❌ "Tu fondo está vacío. Necesitas hacer una aportación inicial."
   - ✅ "Cuando alguien aporte o gaste, los movimientos aparecen acá."

3. **ONE CTA**, not two.
   - ❌ Two equal-weight buttons ("Crear evento" + "Aprender más").
   - ✅ One next action ("Crear evento"), no secondary.
   - The only exception: "Crear / Unirme" pairs on top-of-app empty
     states (no groups yet). Two equally-weighted paths is a real
     decision the user must make.

4. **Use SF Symbols, not illustrations.** Apple's empty states across
   Reminders, Mail, Notes, Wallet, Calendar all use system symbols.
   Custom illustrations look SaaS.

5. **No emojis in empty-state copy.** Calm > playful.

### Six concrete Ruul empty states

#### 3.1 Empty fund

```swift
ContentUnavailableView {
    Label("Empieza tu fondo", systemImage: "creditcard")
} description: {
    Text("Cuando alguien aporte o haya un gasto, los movimientos aparecen acá.")
} actions: {
    Button("Aportar") { coordinator.addContribution() }
        .buttonStyle(.borderedProminent)
}
```

#### 3.2 Empty events (this week)

```swift
ContentUnavailableView {
    Label("Sin eventos esta semana", systemImage: "calendar")
} description: {
    Text("Cuando alguien proponga una cena, va a aparecer acá.")
} actions: {
    Button("Crear evento") { coordinator.createEvent() }
        .buttonStyle(.borderedProminent)
}
```

#### 3.3 Empty members

```swift
ContentUnavailableView {
    Label("Solo estás tú", systemImage: "person.2")
} description: {
    Text("Comparte el código del grupo para invitar a tus amigos.")
} actions: {
    Button("Invitar amigos") { coordinator.invite() }
        .buttonStyle(.borderedProminent)
}
```

#### 3.4 Empty fines

```swift
ContentUnavailableView {
    Label("Sin multas", systemImage: "checkmark.seal")
} description: {
    Text("Por ahora todos cumplieron los acuerdos. Si alguien falla, la regla aplica sola.")
}
// No CTA — empty fines is good news.
```

#### 3.5 Empty votes (no active votes)

```swift
ContentUnavailableView {
    Label("Sin decisiones pendientes", systemImage: "checkmark.square")
} description: {
    Text("Cuando alguien proponga algo a votar, aparece acá.")
}
// No CTA — voting starts from another flow (rules edit, fine appeal).
```

#### 3.6 Empty rules (new group, no rules yet)

```swift
ContentUnavailableView {
    Label("Acuerdos del grupo", systemImage: "list.bullet.clipboard")
} description: {
    Text("Define quién hace qué, cuándo, y qué pasa si alguien no cumple.")
} actions: {
    Button("Agregar primer acuerdo") { coordinator.addRule() }
        .buttonStyle(.borderedProminent)
}
```

### Other Ruul empty states to write (Wave 3 PR)

- Past events list — "Sin eventos pasados" / "Acá vas a ver el historial cuando termine la primera cena."
- Activity feed — "Sin actividad reciente" / "Acá aparece todo lo que pasa en el grupo."
- Inbox — "Estás al día" / "Cuando alguien necesite tu atención, llega acá."
- Profile timeline (MyTimeline) — "Tu historial está vacío" / "Acá vas a ver tus aportes, eventos, y decisiones."
- Search empty result — use `ContentUnavailableView.search(text:)` (Apple-provided).

---

## 4. Forbidden patterns (with concrete examples)

Hard-banned. If a screen contains one of these, it fails doctrine and
must be refactored.

### 4.1 Floating action buttons (FABs)

❌ **Banned**:
```swift
// HomeView with a floating "+" pill at the bottom
ZStack(alignment: .bottomTrailing) {
    list
    FloatingActionButton(systemImage: "plus") { create() }
        .padding()
}
```

✅ **Native**:
```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button { create() } label: { Image(systemName: "plus") }
    }
}
```

Apple's iOS uses the navigation bar or the toolbar bottom bar, not a
hovering circle. FABs are an Android Material pattern.

### 4.2 Toast notifications

❌ **Banned**:
```swift
.ruulToast($toastModel) // auto-dismiss top banner
```

✅ **Native**:
- Errors → `.alert`
- Inline errors → `Section { } footer: { Text(error).foregroundStyle(.red) }`
- Successes → silent (the new state IS the success)

The single exception: **Section footer inline error text** when a
single Form field has an issue. That's not a toast — it lives inside
the Form, doesn't auto-dismiss, doesn't float.

### 4.3 Custom segmented controls

❌ **Banned**:
```swift
RuulSegmentedControl(selection: $tab, segments: [...])
// (glass pill + spring + matchedGeometryEffect)
```

✅ **Native**:
```swift
Picker("Tab", selection: $tab) {
    Text("Resumen").tag(Tab.overview)
    Text("Gente").tag(Tab.people)
}
.pickerStyle(.segmented)
```

### 4.4 Card-stacked dashboards

❌ **Banned**:
```swift
ScrollView {
    VStack(spacing: 16) {
        RuulCard { /* hero balance */ }
        RuulCard { /* upcoming event */ }
        RuulCard { /* recent activity */ }
        RuulCard { /* members */ }
    }
}
```

✅ **Native**:
```swift
List {
    Section { /* hero — LabeledContent or hero Text */ }
    Section("Próximo evento") { /* event row */ }
    Section("Actividad reciente") { /* activity rows */ }
    Section("Miembros") { /* member rows */ }
}
.listStyle(.insetGrouped)
```

A dashboard of cards reads as a SaaS admin panel. A grouped list reads
as an Apple app.

### 4.5 Multi-column layouts on iPhone

❌ **Banned**:
```swift
LazyVGrid(columns: [.init(.flexible()), .init(.flexible())]) {
    ForEach(items) { item in
        Card(item)
    }
}
```

✅ **Native**:
```swift
List {
    ForEach(items) { item in
        ItemRow(item)
    }
}
```

iPhone is a 1-column device. 2+ column grids are for iPad / Mac
(`NavigationSplitView`) or for photo galleries specifically.

### 4.6 Inspector-style sheets (right-rail panel)

❌ **Banned**:
```swift
HStack {
    mainContent
    if showingInspector {
        InspectorPanel()
            .frame(width: 360)
    }
}
```

✅ **Native**:
- iPhone: push to a new screen (`NavigationLink`) or present a
  `.sheet`.
- iPad: use `NavigationSplitView` for split layout.

Side-panel inspectors are a desktop pattern.

### 4.7 Heavy shadows for depth

❌ **Banned**:
```swift
.background(Color.white, in: RoundedRectangle(cornerRadius: 12))
.shadow(color: .black.opacity(0.1), radius: 12, x: 0, y: 4)
.ruulElevation(.md)
```

✅ **Native**:
- Move the content into a `Section` inside a `List`. List handles
  separation.
- If it must float, use `.glassEffect()` — material, not shadow.

Apple's design language is **material**, not shadow. Shadow says
"draggable card"; material says "transient surface".

### 4.8 Mesh gradient screen backgrounds

❌ **Banned**:
```swift
.ruulAmbientScreen(palette: group.ambientPalette)
// (mesh gradient screen background tinted to group color)
```

✅ **Native**:
```swift
// Just leave the default systemBackground / systemGroupedBackground.
// Group identity comes from the avatar + tiny chips, not the screen tint.
```

Per decision #4: group color theming → avatars + dots + chips only.

### 4.9 Branded gradients (multi-color)

❌ **Banned**:
```swift
LinearGradient(colors: [.purple, .pink, .orange], startPoint: .top, endPoint: .bottom)
```

✅ **Native**:
- One accent color (`.tint`) per app.
- Gradients only on user-uploaded cover photos (`Image` from media
  library), never programmatic.
- Status colors (green/red/orange) only on foreground tints, not fills.

### 4.10 Always-visible action buttons sticky to bottom

❌ **Banned**:
```swift
VStack {
    ScrollView { content }
    Spacer()
    HStack {
        RuulButton("Confirmar", style: .primary, fillsWidth: true) { ... }
    }
    .padding()
    .background(.thinMaterial)
}
```

✅ **Native**:
```swift
.toolbar {
    ToolbarItem(placement: .confirmationAction) {
        Button("Confirmar") { ... }
            .disabled(!canConfirm)
    }
}
```

For multi-action bottom bars (e.g. "Voy" / "Tal vez" / "No voy"), use
`.toolbar { ToolbarItemGroup(placement: .bottomBar) { ... } }`. iOS 26
gives that the Liquid Glass treatment automatically.

### 4.11 Hand-rolled drag-to-dismiss / swipe gestures

❌ **Banned**:
```swift
.gesture(DragGesture(minimumDistance: 20).onEnded { gesture in
    if gesture.translation.height > 100 { dismiss() }
})
```

✅ **Native**:
- `.sheet` has swipe-to-dismiss built-in.
- `.swipeActions(edge: .trailing)` for row swipes.
- `.contextMenu` for long-press.

Don't reinvent Apple's gesture handling.

### 4.12 Spinner blockers ("loading takeover" screens)

❌ **Banned**:
```swift
ZStack {
    Color.black.opacity(0.5)
    ProgressView("Loading...")
}
```

✅ **Native**:
- Loading inside a list: render the list with empty rows or a
  `ProgressView()` row at top.
- Pull-to-refresh: `.refreshable { await load() }` — system handles
  the spinner.
- Initial load on a screen: leave the screen empty + show a single
  `ProgressView()` centered. After a short debounce (~200ms) so the
  spinner doesn't flicker. `LoadingDebounce.swift` already does this —
  keep it.

---

## 5. Accessibility + Dynamic Type

These are doctrine-mandatory per `fase1_native_refactor_doctrine.md`
HIG checklist.

### 5.1 Dynamic Type

- Use system font styles (`.body`, `.headline`, etc.). They scale
  automatically.
- DO NOT hardcode `Font.system(size: 17)` unless the size is
  semantically tied to a non-text element (a square icon, an avatar).
- Test at xxxLarge accessibility size. If layout breaks, fix the
  layout, don't constrain the type.

### 5.2 VoiceOver

- Every `Image(systemName:)` used as a tap target needs an
  `.accessibilityLabel("description")`.
- Decorative-only images: `.accessibilityHidden(true)`.
- Custom controls (sliders, pickers) require `.accessibilityValue(...)`.
- Reordered or grouped views: `.accessibilityElement(children: .combine)` or `.combine`.

### 5.3 Touch targets

- Min 44×44 (HIG). `RuulSpacing.minTouchTarget = 44` — keep.
- If the visual element is smaller, wrap in a transparent
  `.contentShape(Rectangle()).frame(minWidth: 44, minHeight: 44)`.

### 5.4 Color contrast

- `.primary`/`.secondary`/`.tertiary` adapt to high-contrast trait
  automatically. Use them.
- Status colors (`.green/.red/.orange`) over light/dark backgrounds:
  Apple's `Color(.systemGreen)` etc. variants are tuned for both.

### 5.5 Reduce Motion

- `@Environment(\.accessibilityReduceMotion)` gates motion-heavy
  effects.
- `.glassEffect()` already respects Reduce Transparency.
- Drop custom spring animations (per simplification plan) — system
  defaults are Reduce Motion-aware.

---

## 6. Tone of voice

Ruul speaks Mexican Spanish (es-MX) by default. The register is:

- **Tú-form** ("¿Vas?", "Crea un evento"), not "usted".
- **Calm and matter-of-fact.** Not playful. Not corporate. Not
  energetic.
- **Action-oriented.** Buttons start with verbs ("Crear", "Invitar",
  "Confirmar"). Sections start with nouns ("Próximo evento",
  "Movimientos recientes").
- **No exclamation marks.** Apple Spanish uses them sparingly; we use
  them never inside the product. Welcome / onboarding may use one
  ("¡Bienvenido!") but the rest of the app does not.
- **No emojis.** None. Anywhere.
- **No "we" / "nosotros" / "ruul team".** The app speaks in the
  imperative or describes the state.
- **No marketing fluff.** ("Una experiencia revolucionaria de
  coordinación social" — never.)
- **No technical leaks.** ("Procesando la transacción en el ledger" —
  never. "Guardando" — yes.)

### Word-by-word tone tests

| Wrong | Right |
|---|---|
| "¡Tu evento se creó con éxito! 🎉" | (silent — the row appears) |
| "Ups, algo salió mal." | "No pudimos guardar. Revisa tu conexión." |
| "Tu mejor amigo te invitó a Cenas Quincenales 🙌" | "Te invitaron a Cenas Quincenales" |
| "Cerrando sesión, espera un momento por favor…" | "Cerrando sesión" |
| "Activa este superpoder para tu grupo" | "Activar [nombre de función] en el grupo" |
| "¡Genial! Tu RSVP fue recibido." | (silent — the segmented control shows your choice) |

---

## 7. Quick checklist (per-screen)

Before approving a screen in PR:

- [ ] No banned vocabulary in any rendered string?
- [ ] Title is sentence case (not Title Case)?
- [ ] Empty state follows 3-part template (icon + title + 1-2 sentences + 0-1 CTA)?
- [ ] No FABs, no toasts, no custom segmented/picker/toggle?
- [ ] No card stacks (uses `List + Section` instead)?
- [ ] No mesh gradient screen background?
- [ ] No `.ruulElevation(...)` shadow chrome?
- [ ] Destructive actions go through `.confirmationDialog`?
- [ ] Errors are `.alert` or inline Section footer, not toast?
- [ ] Success is silent or visible-via-state-change, not toast?
- [ ] Every tap target ≥44×44?
- [ ] Every Image-button has an `.accessibilityLabel`?
- [ ] Dynamic Type xxxLarge doesn't break layout?
- [ ] `.tint(.accentColor)` inherited from app root, not overridden inline?
- [ ] If the screen has `.glassEffect()`: is it on a floating toolbar /
      bottom action bar / transient overlay / media chrome / compact
      control over content?
- [ ] If the screen has group color: is it ONLY on avatars / chips /
      dots, not on backgrounds / cards / gradients?

If any answer is NO → refactor before merge.

---

## 8. What this deliverable does NOT cover

- Per-flow vocabulary mapping (each existing screen → renamed labels).
  That's a Wave 3 PR per flow.
- Resource Detail Activity tab content design — covered conceptually
  in Component Map §10.
- Localization beyond es-MX (en-US comes later).
- Voice-Over scripted walkthroughs.
- Marketing site copy / app store copy.
- Onboarding script revision (separate Wave 3 PR).
