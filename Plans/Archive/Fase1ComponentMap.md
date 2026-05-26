# FASE 1 — Canonical Component Map (Deliverable C)

**Status**: Plan-only, written 2026-05-19. Pairs with
`Fase1SimplificationPlan.md` (Deliverable B) + audit Deliverable A.

**Purpose**: For every Apple-native primitive Ruul uses going forward,
define WHEN to use it, WHEN NOT to use it, the canonical Ruul example,
and which custom component(s) it replaces.

**Order**: most-load-bearing first (List/Section/Form anchor every
detail surface in Ruul; everything else composes on top).

---

## Index

1. [List + Section (insetGrouped)](#1-list--section-insetgrouped) — backbone of every detail surface
2. [Form](#2-form) — config / edit screens
3. [Menu + Picker](#3-menu--picker) — discrete selection
4. [Sheet + presentationDetents](#4-sheet--presentationdetents) — modals
5. [TabView](#5-tabview) — primary navigation
6. [Toolbar + ToolbarItem](#6-toolbar--toolbaritem) — screen actions
7. [NavigationStack + .navigationDestination](#7-navigationstack--navigationdestination) — push navigation
8. [ContentUnavailableView](#8-contentunavailableview) — empty + error states
9. [.searchable](#9-searchable) — search
10. [Activity Feed pattern](#10-activity-feed-pattern) — timeline-style List
11. [ConfirmationDialog + Alert](#11-confirmationdialog--alert) — destructive confirmations

---

## 1. List + Section (insetGrouped)

**The single most important primitive in Ruul going forward.** Every
detail screen, every settings screen, every resource view, every member
list — they all collapse to `List { Section { ... } }` with
`.listStyle(.insetGrouped)`.

### When to use
- Any screen showing a vertical stack of related rows.
- Grouped settings/configuration with section headers.
- Detail surfaces with logical groups (event details, fund details,
  member profile).
- Replacing **every** current `ScrollView { VStack(spacing: ...) }`
  pattern.

### When NOT to use
- True splash / welcome / onboarding hero screens (free-form layout).
- Map / camera / OTP viewfinder surfaces (chromeless takeovers).
- Activity timelines — see §10 for the timeline variant (still a List,
  different row shape).

### Replaces
- `RuulCard`, `RuulActionableCard`, `RuulInfoCard`, `RuulMetricCard`.
- `RuulSeparatedRows`, `RuulListSectionHeader`.
- Every `ScrollView { VStack { ... } }` on a detail screen.
- Custom card stacks on HomeView, fund detail, event detail, member
  list, etc.

### Canonical Ruul example — Event detail (Identity + Coordination/Schedule layers)

```swift
List {
    Section {
        LabeledContent("Cuándo") {
            Text(event.startsAt, format: .dateTime.day().month().hour().minute())
        }
        LabeledContent("Dónde") {
            Text(event.location ?? "Por confirmar")
        }
        if let host = event.host {
            LabeledContent("Anfitrión") {
                Label(host.name, systemImage: "person.crop.circle.fill")
            }
        }
    }

    Section("Asistencia") {
        ForEach(event.attendees) { attendee in
            HStack {
                Label(attendee.name, systemImage: "person.fill")
                Spacer()
                Text(attendee.rsvpStatus.display)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
.listStyle(.insetGrouped)
.navigationTitle(event.title)
```

### Key idioms
- `LabeledContent("Label") { Text(...) }` — the canonical
  key/value row.
- `Section("Header")` for titled sections; `Section { ... } footer: { Text("Help text") }` for inline help.
- `.swipeActions(edge: .trailing) { Button(role: .destructive) {} }` for row actions.
- `.contextMenu { ... }` for less-discoverable actions.
- `.listRowSeparator(.hidden)` only when row visually contains its own divider (rare).

### Anti-patterns
- ❌ `VStack(spacing: RuulSpacing.s8) { sections }` inside a `ScrollView` — replace with List.
- ❌ Cards as rows. A row IS the visual primitive; a card around it is duplication.
- ❌ Custom dividers inside a List — `List` provides them.

---

## 2. Form

A `Form` is a `List` with input-friendly affordances (text fields,
toggles, pickers, date pickers) and tighter row spacing.

### When to use
- Editing or creating a resource (event, fund, rule).
- Settings screens (profile, notification preferences, language).
- Any "Crear nuevo X" / "Editar X" flow.

### When NOT to use
- Read-only detail surfaces (use `List` per §1).
- Onboarding step flows (use `OnboardingScreenTemplate` — kept).
- Wizards with multiple steps + custom progress (push views in a
  `NavigationStack`; each step's body is still a `Form`).

### Replaces
- `ModalSheetTemplate` chrome.
- Custom "edit X" sheet layouts using `ScrollView { VStack { cards } }`.

### Canonical Ruul example — Edit event sheet

```swift
NavigationStack {
    Form {
        Section {
            TextField("Título", text: $draft.title)
            DatePicker("Cuándo", selection: $draft.startsAt)
        }

        Section("Lugar") {
            TextField("Dirección", text: $draft.location)
        }

        Section {
            Toggle("Recurrente", isOn: $draft.isRecurring)
            if draft.isRecurring {
                Picker("Cadencia", selection: $draft.cadence) {
                    Text("Semanal").tag(Cadence.weekly)
                    Text("Quincenal").tag(Cadence.biweekly)
                    Text("Mensual").tag(Cadence.monthly)
                }
            }
        } footer: {
            Text("Crea un evento que se repite automáticamente.")
        }
    }
    .navigationTitle("Editar cena")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancelar") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Guardar") { Task { await save() } }
                .disabled(!draft.hasChanges)
        }
    }
}
```

### Key idioms
- `Section { rows } footer: { Text("help") }` — inline help text under
  a section. Replaces every `RuulInlineMessage(.info)` adjacent to a
  control.
- Disclosure groups for collapsible advanced sections:
  `DisclosureGroup("Opciones avanzadas") { Section { ... } }`.
- `.alert` / `.confirmationDialog` for destructive actions (delete
  event); see §11.

### Anti-patterns
- ❌ Cards inside a Form (`RuulCard { ... }`). Section IS the card.
- ❌ Custom segmented controls inside a Form — use `Picker(.segmented)` or `Picker(.menu)` per §3.
- ❌ Free-form `VStack` inside a Form — break work into Sections.

---

## 3. Menu + Picker

### When to use `Picker`
- Discrete selection from 2-7 options with stable labels.
  - 2-4 options that fit inline: `.pickerStyle(.segmented)`.
  - 5-7 options or longer labels: `.pickerStyle(.menu)` (default).
  - Numeric/date scrolling selection: `.pickerStyle(.wheel)`.

### When to use `Menu`
- A button that reveals a menu of actions, including destructive ones.
- Overflow actions in a toolbar (the `ellipsis` button).
- "More" affordance inside a row.

### Replaces
- `RuulSegmentedControl` → `Picker(.segmented)`.
- `RuulPicker` → `Picker(.menu)` or `.wheel` for cadence-style options.
- `RuulHeaderActions` (toolbar overflow pill) → `Menu { ... } label: { Image(systemName: "ellipsis") }` in a toolbar.

### Canonical Ruul example — RSVP picker in a Form

```swift
Picker("Voy a ir", selection: $rsvpStatus) {
    Text("Sí").tag(RSVPStatus.attending)
    Text("Tal vez").tag(RSVPStatus.maybe)
    Text("No").tag(RSVPStatus.declined)
}
.pickerStyle(.segmented)
```

### Canonical Ruul example — Overflow menu in a toolbar

```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Menu {
            Button("Compartir") { share() }
            Button("Editar") { edit() }
            Divider()
            Button("Cancelar evento", role: .destructive) { cancel() }
        } label: {
            Image(systemName: "ellipsis")
        }
    }
}
```

### Anti-patterns
- ❌ Custom radio-button list (RuulPicker) — use native picker.
- ❌ Glass-pill segmented (RuulSegmentedControl) — use `.pickerStyle(.segmented)`.
- ❌ Menu with 0-1 actions — promote to a direct `Button` in toolbar.
- ❌ Menu with >7 actions — break into multiple toolbar items or push into a settings screen.

---

## 4. Sheet + presentationDetents

### When to use `.sheet`
- Modal flows that are secondary to the screen behind them: filters,
  selectors, "details on this row", quick edits.
- Anything where the user might want to swipe-down to dismiss without
  committing.
- Most "Crear X" / "Editar X" sheets — use `.medium`/`.large` detents
  so the user sees the underlying context.

### When to use `.fullScreenCover`
- Takeover flows: onboarding wizard, OTP entry, camera, full image
  viewer, RSVP confirmation with required choices.
- ANY flow where swipe-to-dismiss is unsafe (might lose state).
- Splash on cold start.

**Note**: this reverses the 2026-05-15 "every modal is fullScreenCover"
policy. See `Fase1SimplificationPlan.md` §7 Open Question #6.

### Replaces
- `RuulSheet` (currently aliases `.fullScreenCover`) → use `.sheet` for
  most call sites, `.fullScreenCover` only for true takeover.
- `RuulFullScreenCover` → `.fullScreenCover` inline.
- `ModalSheetTemplate` → native `NavigationStack { Form { ... } }`
  inside a `.sheet`.

### Canonical Ruul example — Edit member sheet

```swift
.sheet(isPresented: $showingEdit) {
    NavigationStack {
        Form {
            // ... edit fields
        }
        .navigationTitle("Editar miembro")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { showingEdit = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Guardar") { Task { await save() } }
            }
        }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
}
```

### Canonical Ruul example — Takeover OTP entry

```swift
.fullScreenCover(isPresented: $showingOTP) {
    NavigationStack {
        OTPVerifyView(phone: phone) { code in
            Task { await coordinator.verify(code) }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { coordinator.cancelOTP() }
            }
        }
    }
}
```

### Key idioms
- `.presentationDetents([.medium, .large])` — Apple's standard.
- `.presentationDragIndicator(.visible)` for sheets with no clear close
  affordance.
- `.presentationBackgroundInteraction(.enabled(upThrough: .medium))`
  when the user can interact with the background at medium height (rare).

### Anti-patterns
- ❌ Sheet inside a sheet inside a sheet — collapse the flow.
- ❌ `.fullScreenCover` for a filter picker — use `.sheet` with
  `.medium` detent.
- ❌ `xmark` icon as the close affordance on a Form sheet. Apple uses
  `Button("Cancelar")` in `.cancellationAction` placement, sometimes
  paired with `Button("Listo" / "Guardar")` in `.confirmationAction`.
  `xmark` is only for media viewers / image takeovers.

---

## 5. TabView

### When to use
- The app shell, post-onboarding. iOS 26's TabView already renders
  Liquid Glass natively and supports `.tabBarMinimizeBehavior(.onScrollDown)`.
- A 2-5 tab navigation pattern (Apple sweet spot).

### When NOT to use
- Inside a sheet / pushed detail (use `Picker(.segmented)` for in-page
  category switching).
- For 6+ tabs (Apple's limit; use a "More" tab or rethink).

### Replaces
- `RuulTabBar` (custom floating glass bar) — DELETE.
- `ResourceTabBar` template — DELETE; inline `TabView` at the call
  site.

### Canonical Ruul example — Main app shell

```swift
TabView(selection: $selectedTab) {
    HomeView(/* ... */)
        .tabItem { Label("Inicio", systemImage: "house.fill") }
        .tag(Tab.home)

    InboxView(/* ... */)
        .tabItem { Label("Inbox", systemImage: "tray.fill") }
        .badge(inboxCount > 0 ? inboxCount : 0) // 0 hides
        .tag(Tab.inbox)

    RulesView(/* ... */)
        .tabItem { Label("Reglas", systemImage: "list.bullet.clipboard.fill") }
        .tag(Tab.rules)

    ProfileView(/* ... */)
        .tabItem { Label("Yo", systemImage: "person.crop.circle.fill") }
        .tag(Tab.me)
}
.tabBarMinimizeBehavior(.onScrollDown)
// .tint(.accentColor) applied once at app root, not here.
```

### Key idioms
- `.badge(count)` — first-class iOS 17+ badge support on tab items.
- `.tabBarMinimizeBehavior(.onScrollDown)` — iOS 26 native, gains
  vertical real estate on scroll.
- DO NOT call `.toolbarBackground(.ultraThinMaterial, for: .tabBar)` —
  per the comment already in `ResourceTabBar.swift`, that overrides
  the native Liquid Glass with a flat material.

### Anti-patterns
- ❌ Custom tab bar with custom selection animation.
- ❌ TabView inside a TabView.
- ❌ Hiding the tab bar conditionally for "modal" feel — use `.sheet` or `.fullScreenCover` instead.

---

## 6. Toolbar + ToolbarItem

### When to use
- Every screen with primary or secondary actions.
- Modal sheet headers (cancel/save).
- Detail screen overflow menus.
- Bottom-bar actions (multi-select, batch operations) via
  `ToolbarItemGroup(placement: .bottomBar)`.

### When NOT to use
- For navigation back ("Atrás") — `NavigationStack` provides it
  automatically. Don't add a manual back button.
- For destructive primary actions — those go in
  `.confirmationDialog` (§11), not the toolbar.

### Replaces
- `RuulSheetToolbar` (custom modifier).
- `RuulCloseToolbarButton` (custom xmark button).
- `RuulHeaderActions` (custom pill grouping).
- `RuulAppToolbar` (custom toolbar wrapper).

### Canonical Ruul example — Detail screen toolbar

```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Menu {
            Button("Compartir") { share() }
            Button("Editar") { edit() }
            Divider()
            Button("Cancelar evento", role: .destructive) { confirmCancel() }
        } label: {
            Image(systemName: "ellipsis")
        }
    }
}
```

### Canonical Ruul example — Sheet header (replaces `.ruulSheetToolbar`)

```swift
.navigationTitle("Editar grupo")
.navigationBarTitleDisplayMode(.inline)
.toolbar {
    ToolbarItem(placement: .cancellationAction) {
        Button("Cancelar") { dismiss() }
    }
    ToolbarItem(placement: .confirmationAction) {
        Button("Guardar") { Task { await save() } }
            .disabled(!hasChanges)
    }
}
```

### Canonical Ruul example — Bottom action bar (Resource Detail RSVP)

```swift
.toolbar {
    ToolbarItemGroup(placement: .bottomBar) {
        Button { confirm() } label: {
            Label("Voy", systemImage: "checkmark.circle.fill")
        }
        .buttonStyle(.borderedProminent)

        Button { decline() } label: {
            Label("No voy", systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
    }
}
```

### Key idioms
- `.cancellationAction` / `.confirmationAction` placements — Apple
  swaps left/right based on locale automatically.
- `.principal` placement for centered titles when you don't want the
  default `.navigationTitle` chrome.
- `.bottomBar` placement for action bars on detail screens. iOS 26
  Liquid Glass is automatic.

### Anti-patterns
- ❌ Custom Cancel/Save text styled as glass pills.
- ❌ `xmark` icon in `.cancellationAction` slot on Form sheets — use
  text "Cancelar" / "Listo".
- ❌ Multiple competing primary actions in the toolbar — pick one,
  push the rest into a Menu.

---

## 7. NavigationStack + .navigationDestination

### When to use
- Push navigation inside a tab.
- Drill-down from a list row to a detail.
- Multi-step wizards where each step is a push (with native
  back-swipe).

### When NOT to use
- For modal flows — use `.sheet` or `.fullScreenCover` per §4.
- For tab-switching (TabView already handles).
- For deeply branching state machines — those need a coordinator that
  drives the path, not a hand-pushed stack.

### Replaces
- Custom navigation routers that push to glass-pill chrome screens.
- Templates' implicit "wrap in NavigationStack" — explicit at the
  screen entry point.

### Canonical Ruul example — Push from row to detail

```swift
NavigationStack {
    List(groups) { group in
        NavigationLink(value: group) {
            HStack {
                RuulGroupAvatar(group: group, size: .medium)
                VStack(alignment: .leading) {
                    Text(group.name)
                    Text("\(group.memberCount) miembros")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    .navigationDestination(for: RuulCore.Group.self) { group in
        GroupDetailView(group: group)
    }
    .navigationTitle("Mis grupos")
}
```

### Key idioms
- `NavigationLink(value:)` + `.navigationDestination(for:)` for typed
  routing.
- `NavigationLink { Detail() } label: { Row() }` for ad-hoc pushes.
- `@State private var path = NavigationPath()` for programmatic
  navigation.

### Anti-patterns
- ❌ `Button { showDetail = true }` + `.sheet` when the natural flow is
  push (lose back-swipe, lose chrome consistency).
- ❌ Nested NavigationStack inside another NavigationStack on the same
  tab.

### When to use `NavigationLink` vs `Button { sheet }`?

| Action | Use |
|---|---|
| Drill into more info (read-mostly) | `NavigationLink` |
| Quick edit / commit dialog | `Button { sheet }` |
| Multi-step wizard | `Button { fullScreenCover }` containing a `NavigationStack` |
| Destructive confirmation | `Button { confirmationDialog }` |

---

## 8. ContentUnavailableView

Apple's iOS 17+ canonical empty / error state. Already the doctrine
target for `EmptyStateView` and `ErrorStateView`.

### When to use
- Empty list with optional CTA: no events, no fines, no members yet.
- Search returning no results: `.search` variant ships built-in.
- Error state: optional retry action.

### When NOT to use
- Loading state (use `ProgressView()` directly).
- "Permission denied" message (use a Section footer with an inline
  link).

### Replaces
- `EmptyStateView`.
- `ErrorStateView` + `ErrorStateView+CoordinatorError`.

### Canonical Ruul example — Empty events list

```swift
if events.isEmpty {
    ContentUnavailableView {
        Label("Sin eventos esta semana", systemImage: "calendar")
    } description: {
        Text("Cuando alguien proponga una cena, va a aparecer acá.")
    } actions: {
        Button("Crear evento") { coordinator.createEvent() }
            .buttonStyle(.borderedProminent)
    }
}
```

### Canonical Ruul example — Search empty result

```swift
ContentUnavailableView.search(text: searchText)
```

### Canonical Ruul example — Error with retry

```swift
ContentUnavailableView {
    Label("No pudimos cargar", systemImage: "wifi.exclamationmark")
} description: {
    Text("Revisa tu conexión y reintenta.")
} actions: {
    Button("Reintentar") { Task { await coordinator.refresh() } }
}
```

### Key idioms
- `Label("Title", systemImage: "...")` for the title — image + text
  combo Apple uses everywhere.
- One CTA in `actions:` is normal; two (primary + secondary) is rare
  but allowed.
- The description should be 1-2 short sentences — reduces anxiety, points
  to next action. See Deliverable D for the full empty-state template.

### Anti-patterns
- ❌ Custom illustration (large SVG, illustrative drawing) — use an SF
  Symbol. Apple uses symbols, not illustrations.
- ❌ Multiple CTAs of equal weight ("Crear" + "Unirme" + "Aprender más").
  Pick one.
- ❌ Sad-face emojis or playful copy. Doctrine: calm.

---

## 9. .searchable

### When to use
- Every list with more than ~10 items.
- Cross-group / cross-flow search (e.g. Activity history, all members).
- Picker UIs where the list is long (timezone picker, currency picker).

### When NOT to use
- Lists with <10 items (search is overkill).
- Forms (use inline TextField for the field being edited).

### Replaces
- Custom search bars at the top of ScrollViews.
- Filter chips for "search by name" use cases.

### Canonical Ruul example — Members list with search

```swift
List(filteredMembers) { member in
    NavigationLink(value: member) {
        HStack {
            RuulPersonAvatar(member: member, size: .small)
            VStack(alignment: .leading) {
                Text(member.name)
                Text(member.role.display)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
.searchable(text: $searchText, prompt: "Buscar miembros")
.overlay {
    if filteredMembers.isEmpty && !searchText.isEmpty {
        ContentUnavailableView.search(text: searchText)
    }
}
```

### Key idioms
- `.searchable(text: $query, prompt: "Texto de hint")`.
- `.searchScopes($scope, scopes: { ... })` for scoped search (rare).
- `ContentUnavailableView.search(text:)` for empty-search-result.

### Anti-patterns
- ❌ Hidden search bar that only appears on a button tap — Apple's
  pattern reveals on scroll.
- ❌ Custom-styled search field outside `.searchable`.

---

## 10. Activity Feed pattern

A timeline-style list of historical events. Common in Ruul: app-shell
Actividad tab, Universal Resource Detail Activity layer, History sheet,
MyTimeline.

### When to use
- A chronological list of "what happened" with who/what/when.
- Resource Detail Activity layer (per universal-detail doctrine
  2026-05-20: every resource has an Activity layer at the bottom of
  the layered scroll — see §"Universal Resource Detail").
- Profile timeline.

### When NOT to use
- Action lists (use Section in §1).
- Notification inbox (that's its own List with `.badge` on unread
  rows).

### Replaces
- `RuulTimelineItem` (kept as wrapper, but rebuilt internals).
- Custom timeline renderers in feature code.

### Canonical Ruul example — Resource Activity layer

```swift
List {
    Section("Hoy") {
        ForEach(todayEvents) { event in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: event.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.body)
                    Text(event.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(event.timestamp, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }

    Section("Ayer") {
        ForEach(yesterdayEvents) { event in
            // same row shape
        }
    }
}
.listStyle(.insetGrouped)
```

### Key idioms
- Sections by day ("Hoy", "Ayer", "Esta semana", "Antes").
- Leading SF Symbol per row, secondary tint.
- Trailing relative timestamp, tertiary tint.
- 2-line row: title + subtitle (`.body` + `.footnote.secondary`).
- `.swipeActions` for "borrar" / "marcar leído" on inbox-like feeds.

### Anti-patterns
- ❌ Card-per-row layout with shadows.
- ❌ Avatar circles on every row when the actor is implicit (the user
  is reading their own timeline).
- ❌ Custom date dividers as separate rows — use Section headers.

---

## 11. ConfirmationDialog + Alert

### When to use `.confirmationDialog`
- Destructive actions with a confirm step: delete event, remove
  member, cancel attendance, void fine.
- Choosing among a small set of similar options (typically 2-4) after
  tapping a single button.

### When to use `.alert`
- Errors that block progress and need acknowledgment.
- Required confirmations with a single OK ("Tu sesión expiró").
- VERY rarely: a 2-button decision when `.confirmationDialog` would be
  awkward (Apple still prefers `.confirmationDialog` here).

### When to use neither (silent success)
- Successful save → no confirmation needed; the new state IS the
  confirmation (the row appears, the toggle is on, the screen
  dismisses).
- Successful API call → no toast; user sees the visual consequence.

### Replaces
- `RuulToast` (auto-dismiss banner) → for errors, `.alert`; for
  success, NOTHING; for warnings, inline Section footer.
- `RuulInlineMessage` (`.error` style) → Section footer with red text;
  `.alert` only if blocking.

### Canonical Ruul example — Destructive confirmation

```swift
.confirmationDialog(
    "¿Cancelar evento?",
    isPresented: $showingCancelConfirm,
    titleVisibility: .visible
) {
    Button("Cancelar evento", role: .destructive) {
        Task { await coordinator.cancelEvent() }
    }
    Button("No cancelar", role: .cancel) {}
} message: {
    Text("Se notificará a los \(event.attendees.count) asistentes.")
}
```

### Canonical Ruul example — Error alert

```swift
.alert(
    "No pudimos guardar",
    isPresented: $showingError,
    presenting: error
) { _ in
    Button("Reintentar") { Task { await save() } }
    Button("Cancelar", role: .cancel) {}
} message: { error in
    Text(error.localizedDescription)
}
```

### Canonical Ruul example — Inline error in Form

```swift
Form {
    Section {
        TextField("Email", text: $email)
    } footer: {
        if let error = emailError {
            Text(error)
                .foregroundStyle(.red)
        }
    }
}
```

### Key idioms
- `role: .destructive` on destructive buttons — Apple renders in red.
- `role: .cancel` on the cancel button — Apple anchors it last and
  preserves the "swipe down to cancel" gesture.
- `titleVisibility: .visible` to show the dialog title (default hides
  it).
- `presenting:` parameter on `.alert` for typed error payloads.

### Anti-patterns
- ❌ Toast notification on success ("Evento creado ✓"). The user just
  pressed Save — they know.
- ❌ Toast on error. Use `.alert` if blocking, `Section` footer if
  inline.
- ❌ `.alert` for a 4-option menu — use `.confirmationDialog`.
- ❌ Custom dimmed background overlays — `.alert` and
  `.confirmationDialog` handle that natively.

---

## Universal Resource Detail — layered architecture

> **Status (2026-05-20)**: This section SUPERSEDES the prior
> "Resource Detail tab canonical structure" plan that proposed
> `Picker(.segmented)` over five tabs (Resumen / Gente / Dinero /
> Reglas / Actividad) and the PR A-G implementation sequence built on
> it. The tab plan was rejected on doctrine grounds: a segmented
> picker over five mental modes is still a "technical tab" pattern
> and turns the detail into a mini-dashboard. Universal Detail is a
> **layered spatial language**, not a switched dashboard. Companion
> memory: `ruul_universal_detail_layered_doctrine.md`.

### Core principle

The Universal Resource Detail is the heart of Ruul. It is NOT one
screen per resource type — it is ONE spatial language that resolves,
on a single vertical scroll, the five questions every human asks
about anything shared:

1. ¿Qué es esto?       → Identity
2. ¿Quién participa?   → Participation
3. ¿Qué está pasando?  → Activity (recent) + Actions (now)
4. ¿Qué puedo hacer?   → Actions
5. ¿Qué cambió?        → Activity (historical)

The shell never changes. Events, funds, trusts, assets, spaces,
rights, slots all render through the same `UniversalResourceDetailView`.
Per-resource divergence lives in the **block builders**, never in the
view. A user who learns one detail screen has learned all of them.

### The 6 layers (top to bottom in one scroll)

| # | Layer          | Question                          | Always visible? |
|---|----------------|-----------------------------------|------------------|
| 1 | Identity       | ¿Qué es esto?                     | yes — always at top |
| 2 | Context        | ¿Por qué existe esto?             | when there's a non-trivial description, purpose, or link to other resources |
| 3 | Participation  | ¿Quién está involucrado y cómo?   | when there's at least one human associated (RSVP, beneficiary, custodian, owner, member, host) |
| 4 | Coordination   | ¿Qué se está coordinando?         | when the resource has any coordination block (see grammar below) |
| 5 | Activity       | ¿Qué pasó?                        | when there's any human-readable activity entry |
| 6 | Actions        | ¿Qué puedo hacer?                 | toolbar always; inline contextual CTAs per block |

### Coordination — the reusable block grammar

The Coordination layer is composed of universal blocks. A resource
opts in to a block by having data; the block hides itself when empty.

| Block            | Reusable for                                                      |
|------------------|-------------------------------------------------------------------|
| **Money**        | funds, fines, expenses, trust distributions, settlements          |
| **Schedule**     | events, rotations, recurrence, reservations                       |
| **Access**       | tickets, spaces, rights, slots, bookings                          |
| **Responsibility** | custodies, ownership, host assignments, beneficiaries, maintenance |
| **Rules**        | active rules, votes, agreements, limits                           |
| **Usage**        | check-ins, occupancy, asset usage logs                            |

These are NOT tabs. They are blocks stacked inside Coordination, in
priority order, on the same vertical scroll.

### Identity layer — what it must contain

- Title (resource name).
- Short subtitle answering "what is this?" in human terms — NOT
  "Recurso: Fondo" or "ResourceType.fund". Examples:
  - Fondo "Viaje Japón": "$48,000 MXN disponibles · 4 aportando"
  - Cena Shabat: "Mañana 8:00 PM · 14 personas"
  - Palco Mundial: "10 lugares · Activo"
  - Fideicomiso Familiar: "4 beneficiarios · Activo"
- State chip when meaningful (Activo / Pendiente / Cerrado /
  Cancelado) — sentence case, never CAPS.
- Viewer's relationship to the resource when it exists ("Eres
  anfitrión", "Aportaste $500 este mes") — surfaced inline below
  the subtitle, NOT in a separate "you" block.

### Context layer — what it must contain

- Description (human, founder-authored or first-person).
- Linked resources (related event for a fund's expense, parent series
  of a recurring event) shown as a rail of cards.
- Tags — only if user-added; never ontology-derived.

Banned vocabulary in Context layer (and everywhere user-facing):
Capability, Module, Governance, Atom, Projection, Trigger,
Consequence, ResourceType, "resource type", "resource graph", "link".

### Participation layer — what it must contain

The most reusable layer. It hosts:
- People (avatar + name + role + state-of-participation).
- Quick-action contextual CTA per row when the viewer has permission
  ("Confirmar asistencia" inline on the viewer's own row, "Invitar"
  on the section header).

Same shape for: event attendees, fund contributors, asset custodians,
trust beneficiaries, space members, slot rotation, right holders.
The Participation block does NOT change with resource type — only the
role labels and state strings change.

### Coordination layer — composition rules

- Blocks render in priority order (Money > Schedule > Access >
  Responsibility > Rules > Usage). Priority is *display order*, not
  importance — every block that has data shows.
- Each block has its own canonical layout shared across resource
  types. A Money block reads identically inside a fund, a fine, and a
  trust distribution.
- Each block is composed as a `Section` inside the host `List`. The
  whole detail is **one List** — Coordination is not a sub-scroll, not
  a sub-TabView, not a Picker.

### Activity layer — what it must contain

Human-readable, append-only timeline. Examples:
- "Linda agregó un gasto de $1,200"
- "José confirmó asistencia"
- "Se cerró la votación"
- "Se asignó custodia a Andrés"
- "Se pagó la multa"

Banned in Activity:
- Raw `system_events` strings.
- Audit-table rows.
- Technical event_type identifiers.
- Metadata diffs.

Activity is Ruul's trust signal. If a user can read 10 activity rows
and immediately understand what happened, the layer is doing its job.

### Action layer — toolbar + inline

The action layer lives in the toolbar:

```
[X]   Title   [+]  [⚙]
```

- `[X]` — sheet/cover dismiss.
- `[+]` — Compose menu. Human verbs ("Invitar", "Agregar gasto",
  "Registrar pago", "Asignar custodia", "Agregar regla"). Sentence
  case; verb + noun.
- `[⚙]` — Settings: configuration only, NEVER primary actions.

Inline CTAs inside blocks (e.g. "Confirmar asistencia" on a row in
Participation, "Aportar" on the Money block header) are also part of
the action layer — they live in their host block, not the toolbar.

### Implementation skeleton

```swift
struct UniversalResourceDetailView: View {
    let blocks: ResourceBlocks  // builder output (per-resource-type)

    var body: some View {
        List {
            IdentitySection(identity: blocks.identity)
            if blocks.context.isPresent {
                ContextSection(context: blocks.context)
            }
            if blocks.participation.isPresent {
                ParticipationSection(participation: blocks.participation)
            }
            // Money / Schedule / Access / Responsibility / Rules / Usage
            CoordinationSections(blocks: blocks.coordination)
            if !blocks.activityHead.isEmpty {
                ActivitySection(
                    entries: blocks.activityHead,
                    hasMore: blocks.hasMoreActivity
                )
            }
        }
        .listStyle(.insetGrouped)
        .toolbar { /* [X] close · [+] compose menu · [⚙] settings */ }
    }
}
```

Each `XxxSection` is a `Section { … }` inside the parent `List`. No
nested `ScrollView`, no `TabView`, no `Picker(.segmented)`.

### Anti-patterns (Universal Detail-specific)

- ❌ `Picker(.segmented)` for "mode" switching ("Resumen / Gente /
  Dinero / Reglas / Actividad" or any other split).
- ❌ `TabView` nested inside the detail.
- ❌ "Capability sections" labeled by capability id.
- ❌ Per-resource-type custom shells (`EventDetailView` vs
  `FundDetailView` diverging at the UI layer — divergence belongs in
  the builder).
- ❌ Toolbar entries named "Capabilities", "Modules", "Governance",
  "Atom", "Projection", "Links".
- ❌ Different mental models per resource type — same layers, same
  block grammar, just different content.

### Apple references

Should feel like:
- Wallet card detail (header + scrollable history).
- Calendar event detail (blocks stacked).
- Reminders list detail (blocks stacked).
- Find My item detail (blocks stacked).
- Home accessory detail (blocks stacked).

Should NOT feel like:
- Airtable record (tabbed fields).
- Notion page (free-form blocks).
- Linear issue (tabbed sidebar).
- Jira ticket.
- ERP master record.

### PR sequence (supersedes prior PR A-G tab plan)

| # | Title | Scope |
|---|---|---|
| 1 | **Doctrine doc rewrite** | This section + new memory entry + plan §6 update. Docs only, no code. |
| 2 | **Extract Identity / Context / Activity blocks** | Pull the three least-contentious layers into their own `Section` views inside the existing one-scroll detail. Re-use existing builders' output. No visual regression — same content, cleaner composition. |
| 3 | **Extract Participation block** | Pull RSVP / attendees / contributors / custodians / beneficiaries into one `ParticipationSection` whose shape is identical across resource types. Inline contextual CTAs per row (viewer permission gated). |
| 4 | **Extract Coordination blocks: Money / Schedule / Access / Rules** | The big one. Replaces capability-named blocks with universal block primitives (`MoneyBlock`, `ScheduleBlock`, `AccessBlock`, `RulesBlock`). Each block reads identically across resource types. |
| 5 | **Normalize action layer: `[+]` menu + `[⚙]` settings** | Collapse the existing overflow `…` menu into the canonical `[+]` (compose) and `[⚙]` (config) split. Inline CTAs move into their host block. |
| 6 | **Remove old duplicate card patterns** | Delete legacy capability-named views + per-resource-type builders that PRs 2-5 made redundant. |
| 7 | **Apple-native polish** | Materials, vibrancy, dynamic type, motion. Calendar / Wallet feel verification on device. |

**Cadence rule**: every PR keeps the detail screen usable end-to-end.
No visual regression. No placeholder tabs. No "coming soon" surfaces.
Producto primero.

### Stop conditions

- If extracting a layer requires data the builders don't produce, the
  PR description must call out the gap; we add a separate builder-side
  PR before continuing — never bolt data fetching onto the View.
- If two resource types want diverging block content (e.g. event Money
  needs RSVP plus-one info that fund Money doesn't), the divergence
  lives in the builder, NEVER in the View. The View stays universal.
- `FineDetailHost` and `VoteDetailHost` also currently render through
  `UniversalResourceDetailView`. They are NOT resources per the
  ontology (governance artifacts), so they may legitimately diverge —
  to be decided per-PR when each layer is extracted. Default
  assumption: fines and votes get the same layered shell.

---

## Quick-reference decision matrix

| User intent | Primitive |
|---|---|
| Show a list of related items | List + Section |
| Edit / create | Form |
| Select from few options | Picker (segmented/menu/wheel) |
| Reveal a menu of actions | Menu |
| Modal flow secondary to current screen | .sheet + presentationDetents |
| Takeover flow (wizard, OTP, camera) | .fullScreenCover |
| Confirm a destructive action | .confirmationDialog |
| Block on error | .alert |
| Empty state | ContentUnavailableView |
| Empty search result | ContentUnavailableView.search(text:) |
| Push to detail | NavigationStack + NavigationLink |
| Primary tabbed navigation (app shell) | TabView |
| In-page tab switching | Picker(.segmented) — but NOT for Universal Resource Detail (layered scroll, see §"Universal Resource Detail") |
| Search within a list | .searchable |
| Chronological list of events | List of rows (timeline pattern) |
| Toolbar action | .toolbar { ToolbarItem } |
| Bottom action bar | .toolbar { ToolbarItemGroup(placement: .bottomBar) } |
| Long-press secondary actions | .contextMenu |
| Trailing swipe actions on row | .swipeActions(edge: .trailing) |

---

## Anti-pattern summary (cross-component)

These show up everywhere across the current Ruul codebase. Each
violates one or more native canon principles:

- **Cards as the screen primitive** — replace with Section in List.
- **Glass on every surface** — only on floating toolbar / bottom bar / transient overlays.
- **Custom segmented controls / pickers / toggles** — use native.
- **Toast notifications** — use Alert or silent success.
- **Custom tab bars** — use TabView.
- **Custom typography** — use system styles.
- **Shadows for depth** — use materials / native presentation.
- **Mesh-gradient screen backgrounds** — use systemBackground / systemGroupedBackground.
- **Uppercase section headers** — let List/Section provide.
- **Inverse colors on accent fills** — let .borderedProminent handle.
- **Modal-in-modal stacks** — collapse the flow.
- **Tabbed Universal Resource Detail** — Resource Detail is a layered
  vertical scroll (Identity / Context / Participation / Coordination /
  Activity / Actions), never a `Picker(.segmented)` or nested
  `TabView`. See §"Universal Resource Detail — layered architecture".
- **Capability- or module-named UI** — banned in user-facing strings
  (Capability, Module, Governance, Atom, Projection, Trigger,
  Consequence, "resource type"). Use human verbs and nouns.

If a screen breaks any of these, the screen is doctrine-incompatible
and needs refactor.
