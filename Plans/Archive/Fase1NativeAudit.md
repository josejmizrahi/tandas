# FASE 1 — Apple Native UI Audit (Deliverable A)

**Status**: Read-only audit, written 2026-05-19.
**Scope**: Entire iOS UI layer in `ios/Packages/RuulUI/` + `ios/Packages/RuulFeatures/.../Features/`.
**Doctrine source**: `~/Library/.../memory/fase1_native_refactor_doctrine.md`.

---

## TL;DR

Ruul currently ships a **comprehensive custom design system** (89 RuulUI files, custom typography in **Inter Variable** font, custom semantic color palette, custom spacing tokens, ~30 custom primitive components) consumed by **143 feature files** with **3,045 references** to custom tokens. The system is internally consistent and well-engineered, but it produces a "premium SaaS" aesthetic — not an Apple first-party feel.

The work to bring it to native is large but mostly **mechanical** (replace tokens, swap primitives), with a smaller subset of **structural** changes (replace custom segmented control, toast, tab bar; remove governance vocabulary; restructure resource detail tabs).

**Critical findings, ranked by blast radius:**
1. **Inter font everywhere** — every `Text` view renders in Inter, not San Francisco. Hard violation of "native typography hierarchy." This is the single largest aesthetic divergence from Apple apps.
2. **Custom semantic colors layered on top of system materials** — `Color.ruulTextPrimary` instead of `.primary`, `Color.ruulBackground` instead of `Color(.systemBackground)`, etc. Dynamic + accessibility-aware, but doctrine mandates `.primary/.secondary/.tertiary/.tint`.
3. **Custom primitive components replacing native ones** — `RuulSegmentedControl`, `RuulTabBar`, `RuulToast`, `RuulPicker`, `RuulSheet`, `RuulButton`, `RuulCard*`. Each adds custom spring animations, glass effects, and shadows that violate the "subtle native motion only" rule.
4. **"Card-heavy" detail screens** — fund/event/resource details use stacked `RuulCard` containers with shadows and gradient backgrounds, rather than `Form { Section {} }` insetGrouped lists.
5. **Governance vocabulary leaking into UX** — a dedicated `GovernanceView` screen titled "Gobierno"; copy mentions "Editar gobierno", "permission level", "modifyGovernance". Doctrine forbids "governance" in user-facing copy.
6. **`MyLedger` user-facing screen** — title "Mis movimientos" probably OK, but the routing identifier `fund.ledger` and the coordinator filename `MyLedgerCoordinator.swift` keep the ontology surfaced.
7. **Custom navigation chrome** — `RuulSheetToolbar`, `RuulAppToolbar`, `RuulHeaderActions`, `RuulCloseToolbarButton`, `RuulInlineActionBar`, `ModalSheetTemplate`. These wrap or replace native `.toolbar { ToolbarItem }`.
8. **Custom backgrounds** — `RuulAmbientBackground`, `RuulMeshBackground`, `RuulCoverPalette`, `ruulAmbientScreen` modifier. Gradient mesh backgrounds violate "calm spatial clarity"; native apps default to system materials.

---

## 1. Scale of the custom design system

**Counts** (factual, gathered via Bash + Grep):

| Surface | Count |
|---|---|
| RuulUI Swift files | 89 |
| RuulFeatures Swift files | 209 |
| RuulFeatures files referencing custom tokens (`Color.ruul*`, `RuulSpacing.*`, `RuulTypography.*`, `RuulRadius.*`, `RuulShadow.*`, `RuulMotion.*`) | 143 |
| Total token references in feature code | 3,045 |
| Custom primitives in `RuulUI/Primitives/` | 41 files |
| Custom modifiers | 8 |
| Custom patterns | 13 |
| Custom templates (Onboarding, Detail, Modal, MainApp, ResourceTabBar) | 5 |
| Custom theme tokens (RuulColors / RuulTypography / RuulSpacing / RuulRadius / RuulShadow / RuulMotion / RuulHaptics / RuulGlass / RuulElevation / RuulOpacity / RuulSize) | 11 token files |

**Feature-folder file counts** (largest first):

| Feature | Files |
|---|---|
| Resources | 79 |
| Votes | 18 |
| Onboarding | 18 |
| Shell | 14 |
| Fines | 14 |
| Rules | 13 |
| Profile | 12 |
| Group | 11 |
| Members | 9 |
| Inbox | 4 |
| Groups | 4 |
| Activity | 4 |
| Feed | 3 |
| Home | 2 |
| Claims | 2 |
| Auth | 2 |

Resources alone is 38% of the feature code surface and contains the most complex screens (Resource detail, blocks, layouts, sheets).

---

## 2. Custom token system → native equivalents

| Custom token | Apple-native replacement | Refactor cost |
|---|---|---|
| `Color.ruulTextPrimary` | `.primary` | mechanical, find-replace |
| `Color.ruulTextSecondary` | `.secondary` | mechanical |
| `Color.ruulTextTertiary` | `Color.secondary.opacity(0.6)` or `.tertiary` (where available) | mechanical |
| `Color.ruulAccent` / `Color.ruulAccentPrimary` | `.tint` (or `.accentColor`) | mechanical — but need to pick ONE accent color globally |
| `Color.ruulBackground` / `Color.ruulSurface` | `Color(.systemBackground)`, `Color(.secondarySystemBackground)`, `Color(.systemGroupedBackground)` | mechanical, context-aware |
| `Color.ruulSeparator` | `Color(.separator)` | mechanical |
| `Color.ruulPositive` / `.ruulNegative` / `.ruulWarning` / `.ruulInfo` | `.green` / `.red` / `.orange` / `.blue` (`Color(.systemGreen)` etc.) | mechanical |
| `RuulTypography.body` (Inter, custom size, custom tracking) | `.body` | **structural** — affects every Text view, will reflow layout |
| `RuulTypography.headline` | `.headline` | structural |
| `RuulTypography.title` / `.titleLarge` | `.title2` / `.title` | structural |
| `RuulTypography.displayHero` / `.displayLarge` / `.displayMedium` | `.largeTitle` (only navigation titles should use this size) | structural — current display sizes are bigger than Apple's `.largeTitle` |
| `RuulTypography.wordmark` (88pt brand mark) | DELETE or replace with `Image("RuulWordmark")` text-as-image | structural |
| `RuulTypography.footnote` (uppercase tracking) | `.footnote` (NO uppercase — that's a SaaS pattern) | structural |
| `RuulTypography.sectionLabel` (uppercase monospace bold) | `Text(...).font(.footnote).foregroundStyle(.secondary)` inside a Section header; let `List` provide chrome | structural |
| `RuulSpacing.s1-s12` (4pt grid: 4/8/12/16/20/24/32/40/48/64/80/96) | Keep tokens for layout, but inside Forms/Lists use native paddings | mechanical inside Form, structural where ad-hoc layouts replace native containers |
| `RuulRadius.*` | Native: `RoundedRectangle(cornerRadius: 10)` for cards, but prefer `Section`/`GroupBox` for grouped content where no radius is needed | structural |
| `RuulShadow.*` / `RuulElevation.*` | DELETE most usages. Apple uses materials + separators, not shadows. Keep only floating elements (system already does). | structural |
| `RuulMotion.*` (custom spring presets) | Use `.default` / `.smooth` / native sheet+nav transitions only. DELETE custom `withAnimation(.ruulSnappy)` etc. | structural |

**Doctrine alignment**: typography + color are the biggest tells. Even keeping every other thing identical, switching to system typography + semantic colors would move the app ~60% toward "feels like Apple."

---

## 3. Custom primitives → native equivalents

Each primitive in `RuulUI/Primitives/` ranked by **doctrine-violation severity** + **call-site count**:

### A. DELETE outright (native equivalent exists and is canonical)

| Primitive | Native replacement | Notes |
|---|---|---|
| `RuulSegmentedControl` | `Picker(selection:) { ... }.pickerStyle(.segmented)` | Custom version uses glass + spring + custom typography — violates "native segmented controls" rule |
| `RuulTabBar` | `TabView { ... }.tabViewStyle(.tabBarOnly)` (or default) | Custom version with custom shadows/spacing |
| `RuulPicker` | `Picker(selection:) { ... }` (menu or wheel) | Custom dropdown with glass styling |
| `RuulToast` | `.alert(...)` for errors, or inline `Text(...)` in a `Section`, or native `ContentUnavailableView` (iOS 17+) | "Lightweight toast" with auto-dismiss + glass — violates "custom toast systems" rule |
| `RuulToggle` | `Toggle(...)` | Verify the custom one isn't just styling; if it adds business logic, refactor that out |
| `RuulSheet` | `.sheet(isPresented:)` (or `.presentationDetents`) | Wraps native sheet with extra chrome |
| `RuulFullScreenCover` | `.fullScreenCover(isPresented:)` | Same |
| `RuulCloseToolbarButton` | `Button { } label: { Image(systemName: "xmark") }` in `ToolbarItem(placement: .topBarLeading)` | One-liner native |
| `RuulPillButton` | `Button` with `.bordered` or `.borderedProminent` style | Apple uses `.bordered`/`.glass`/`.plain` — those are the canonical sizes |
| `RuulCard` | DELETE. Replace with `Section { Row }` inside a `List` | The card metaphor is SaaS; native iOS prefers grouped lists |
| `RuulActionableCard` | DELETE. Use `Button + NavigationLink` inside a `List` | Same |
| `RuulInfoCard` | Replace with `Label` + `Text` inside a `Section`, or `GroupBox` | Same |
| `RuulMetricCard` | For balance/totals: `Text.font(.title)` in a `Section`. For dashboards: redesign as `LabeledContent` rows | Dashboard pattern violates "minimum chrome" |
| `RuulAmbientBackground` | DELETE. Use `Color(.systemBackground)` or `Color(.systemGroupedBackground)` | Mesh gradient backgrounds are a SaaS tell |
| `RuulMeshBackground` | DELETE | Same |
| `ActionCard` (separate file from Ruul*) | Inspect — likely DELETE | TBC |
| `RuulInlineActionBar` | Native `.toolbar { ToolbarItemGroup(placement: .bottomBar) }` | Or move actions to swipeActions / context menus |
| `RuulHeaderActions` | Native `.toolbar { ToolbarItem }` | |
| `RuulChip` | If used for filter UI: `Picker(.segmented)` or `Menu`. If for tags: `Text + .background(.tint.opacity(0.15))` inline | Custom chip != Apple pattern |
| `RuulBadge` | Native `.badge(...)` modifier on `TabView` / `List` rows | iOS has first-class badges now |
| `RuulIconBadge` | Native `.badge(...)` | Same |

### B. KEEP as wrappers — but rebuild internals to use native primitives

| Primitive | Reason to keep | Refactor scope |
|---|---|---|
| `RuulButton` | Centralizes loading/disabled/haptic feedback semantics across the app. Worth keeping as a thin wrapper. | Strip custom backgrounds, use `.buttonStyle(.bordered)` / `.borderedProminent` / `.glass`. Keep `isLoading` indicator behavior. |
| `RuulAvatar`, `RuulAvatarStack`, `RuulPersonAvatar`, `RuulGroupAvatar` | Profile photos with fallback initials are a common Ruul pattern; no native equivalent | Keep, but use system font for initials text |
| `RuulOTPInput` | OTP entry has specific keyboard + autofill semantics. Custom UI is justified. | Keep, audit for system OTP autofill compliance |
| `RuulPhoneField` | Phone number formatting + country code is non-trivial | Keep, audit |
| `RuulDatePicker` | If thin wrapper around `DatePicker`, keep; if heavy custom UI, replace with native | Audit first |
| `RuulProgressBar` | Compare to native `ProgressView(value:)`. If equivalent, DELETE. | Audit |
| `RuulMoneyView` | Money formatting is a domain concern (currency, locale). Worth keeping as a formatter wrapper. | Keep, ensure it uses `.body`/`.headline` system typography |
| `RuulTimelineItem` | Custom activity timeline rendering — if used heavily in Activity feed, keep but lighten | Audit |
| `RuulOriginTag` | Domain-specific (event origin badge?) | Audit |
| `RuulOpacity`, `RuulSize` tokens | Layout-only, no aesthetic | Keep |

### C. INVESTIGATE / TBD

- `RuulInlineProgress`, `RuulInlineMessage`, `RuulListSectionHeader`, `RuulInfoCard`, `RuulQuietActionBar`, `EventCardStub`, `FineCardStub`, `MemberRowStub`, `RuleCardStub`, `RuulSeparatedRows`, `TemplatePickerCard`, `TimezonePicker`, `RuulCoverCatalog`, `RuulCoverPalette` — need per-file inspection to decide delete/keep/wrap.

### D. Templates (`RuulUI/Templates/`)

| Template | Decision |
|---|---|
| `MainAppScreenTemplate` | DELETE. Replace with `NavigationStack { ... }` directly in each screen. Templates are SaaS. |
| `DetailScreenTemplate` | DELETE. Same. |
| `ModalSheetTemplate` | DELETE. Use `.sheet { NavigationStack { ... } }` per-call. |
| `OnboardingScreenTemplate` | KEEP if it standardizes the onboarding step UX. AUDIT first. |
| `ResourceTabBar` | DELETE. Replace with native `TabView` inside the detail. **High-priority** — resource detail is the most complex screen and its tab bar is custom. |

---

## 4. Patterns (`RuulUI/Patterns/`)

| Pattern | Native equivalent | Decision |
|---|---|---|
| `EmptyStateView` | iOS 17+ `ContentUnavailableView` | REPLACE. ContentUnavailableView has built-in title + description + image + action button — exactly the pattern doctrine wants. |
| `ErrorStateView` | `ContentUnavailableView(label:description:actions:)` | REPLACE. |
| `AsyncContentView` | Native `.task { ... }` + `if/else` rendering, or `.refreshable` for refresh | KEEP as a thin wrapper if it reduces boilerplate; otherwise inline. |
| `RuulLoadingState` | `ProgressView()` inside `.overlay` or as a row | DELETE. Native `ProgressView` is canonical. |
| `RuulInlineProgress` | `ProgressView(value: progress)` | DELETE if redundant. |
| `RSVPStateView` | Domain-specific. Keep, but rebuild internals. | KEEP, refactor to native primitives. |
| `OnboardingStepContainer` | Keep if it standardizes onboarding chrome (button + progress) | AUDIT |
| `*Stub` files (EventCardStub, FineCardStub, MemberRowStub, RuleCardStub) | These are placeholder/preview renderers | KEEP if used for previews; otherwise DELETE |
| `RuulSeparatedRows` | Native `List` has dividers built-in | DELETE if used outside `List`. |
| `TimezonePicker` | Domain-specific | KEEP |

---

## 5. Modifiers (`RuulUI/Modifiers/`)

| Modifier | Decision |
|---|---|
| `GlassEffect+Ruul` (extends `.glassEffect()`) | KEEP — iOS 26 native `.glassEffect()` is the primary medium; this just adds Ruul-specific tinting which is fine if subtle |
| `RuulAmbientScreen` | DELETE. Mesh gradient screen backgrounds violate doctrine. |
| `RuulCoverPalette` | AUDIT. If for group cover photos, fine; if for ambient backgrounds, delete. |
| `RuulSheetToolbar` | DELETE. Use `.toolbar { ToolbarItem(placement: .topBarLeading/Trailing) }` directly. |
| `RuulSurfaceStyle` | DELETE if it just applies card chrome. |
| `LoadingDebounce` | KEEP — debouncing the loading indicator avoids flicker, useful pattern. |
| `PressFeedback` | AUDIT. If it adds haptics on press, fine. If it scales the view (custom motion), align to native. |

---

## 6. Prohibited vocabulary in user-facing UI

**Doctrine ban list**: capability, module, projection, atom, resource_type, trigger, consequence, rule shape, governance hierarchy, ledger.

**Replace with**: people, activity, money, rules, schedule, access, history, ownership, participation.

### Direct user-visible violations found:

| File | Violation | Suggested replacement |
|---|---|---|
| `Group/Subscreens/GovernanceView.swift` (title: "Gobierno") | Whole screen titled "Gobierno" with subsections "¿Quién modifica las reglas?", "¿Quién inicia votaciones?" | Rename to "Reglas del grupo" or "Decisiones del grupo". Restructure as a single Form with one Section per question. |
| `Resources/Detail/Sections/EditRightSheet.swift` line 93 | Label "Capability gobernada (opcional)" | Rename. Probably "Permiso vinculado (opcional)" or just remove the field from the UI if it's an advanced/internal control. |
| `Resources/Detail/Blocks/CapabilityBlockView.swift` (filename) | File-level naming — only matters if the view is user-visible | Rename to `EnabledFeaturesBlockView` or similar. Check the Block label rendered. |
| `Profile/Views/MyLedgerView.swift` (filename + coordinator) | "Ledger" appears in code paths; check rendered title | If title is "Mis movimientos" or "Mi historial de dinero", that's fine — but the deeplink `fund.ledger` should be `fund.money` or `fund.history`. |
| `Profile/Views/MyProfileView.swift` line 386 | Comment: "Demote ResourceWizardSheet to Governance → Advanced" — reflects an internal screen hierarchy of "Governance" | Verify the runtime label. Internal comments are fine but if the navigation destination is labelled "Governance" in UI, rename. |
| `Resources/Detail/Sections/RotationParticipantsSheet.swift` line 24 (comment) | Comment notes "no capability, no atom, no rotation engine" — signals the team is aware, audit anyway | OK, internal awareness. Verify rendered copy is clean. |
| `Resources/ResourceWizardSheet.swift` | "ResourceWizard" — the user shouldn't see "resource" as a noun | Rename surface to "Crear cosa nueva en el grupo" or surface specific options (Crear evento, Crear fondo, etc.) without an abstract "resource" container |

### Secondary risk (internal, but worth a check):

- 17 files contain the words `capability`, `module`, `projection`, `atom`, `trigger`, `consequence`, `governance`, or `ledger` in code (mostly logging, error parsing, internal data keys). Internal usage is fine; **all UI-rendered strings need a sweep**.

### Recommended approach

Run a final sweep tool: walk every `Text("...")`, `Label("...", systemImage:)`, `LocalizedStringKey`, `Picker`-option label, `Button("...")`, `Section("...")`, `.navigationTitle(...)`, `.toolbar { ... Text(...) ... }` and check against the ban list. Auto-grep can find candidates; human review picks replacements.

---

## 7. Sample feature-screen findings

### `HomeView.swift` (the home tab)

- Custom layout: `ScrollView { VStack(spacing: RuulSpacing.s8) { sections } }`. **Doctrine says: use `List { Section {} }` for vertical card stacks.** A native Reminders-style List with grouped Sections would feel more native.
- Sections: "pendings", "upcoming feed", "group memory", "past events link" — these map naturally to `Section`s in a `List`.
- `scrollEdgeEffectStyle(.soft, for: .vertical)` is native and correct.
- Padding uses custom tokens (`RuulSpacing.lg`, `RuulSpacing.s8`, `RuulSpacing.s12`). Most will disappear if we switch to `List`/`Form`.

### `GovernanceView.swift` (post-onboarding governance editor)

- Whole screen is **doctrine violation #5** (governance vocabulary).
- Layout: stacked custom "permission cards" with subtitles + radio-button-like selection.
- Native equivalent: a `Form` with one `Section` per question, `Picker(selection:) { Text("Solo el fundador").tag(...); Text("Cualquier miembro").tag(...) }` for each.
- Save button: should live in `.toolbar { ToolbarItem(.confirmationAction) { Button("Listo") {} } }`.

### `RuulSegmentedControl` (custom segmented control)

- Glass + custom typography + spring animation + matchedGeometryEffect.
- Native `Picker(.segmented)` has all the affordances Apple users expect (haptics, accessibility, dynamic type, contrast).
- **Replace everywhere it's called.** Should be ~5-10 call sites at most.

### `RuulToast` (custom top-banner notification)

- Glass card with icon + title + message, auto-dismisses.
- Apple convention: **don't use toasts**. Errors go in a `.alert`; successes are confirmed by the action's visual consequence (the new row appears in the list). Doctrine: "No floating widgets."
- **Replace toast call sites case-by-case**: errors → `.alert`, info → inline `Section` footer, success → just complete the action without notification.

### `RuulTypography.swift` (Inter Variable font)

- Bundled `InterVariable.ttf`. Every `Text` view uses `.ruulTextStyle(RuulTypography.X)` which sets `.font(.custom("InterVariable", ...))` with hand-picked sizes/trackings.
- **The single biggest aesthetic difference from a first-party Apple app.** Replacing this with system styles (`.body`, `.headline`, etc.) flips the perception immediately.

---

## 8. Refactor priority + sequencing (recommended)

Three waves, smallest-blast-radius first:

### Wave 1 — Token replacement (mechanical, no UX change)

PRs 1-4, ordered by reach:

1. **Typography migration**: replace `RuulTypography.X` → `.font(.X)` system across all 143 feature files. Auto-mappable. Single mechanical PR. **Highest visual impact per line of code changed.**
2. **Color migration**: replace `Color.ruul*` → semantic system colors. Mostly mechanical; ambiguous mappings (e.g., `ruulSurface` could be `.background` or `.secondaryBackground` depending on context) need manual decisions. Could be 2-3 PRs.
3. **Spacing migration**: replace `RuulSpacing.X` literals. Most can stay (they're just 4pt grid numbers) but where used inside `Form`/`List`, replace with native `.padding()` defaults.
4. **Delete custom motion/shadow tokens**: replace `withAnimation(.ruulSnappy)` → `withAnimation` (default), delete `ruulElevation` modifiers and let native materials provide depth.

### Wave 2 — Primitive replacement (semi-mechanical, some UX change)

PRs 5-12, one per primitive batch:

5. Replace `RuulSegmentedControl` → `Picker(.segmented)`.
6. Replace `RuulTabBar` / `ResourceTabBar` template → native `TabView`.
7. Replace `RuulToast` → `.alert` / inline Section / no notification (per call site).
8. Replace `RuulPicker` → `Picker(.menu)` or `Picker(.wheel)`.
9. Replace `RuulSheet` / `RuulFullScreenCover` wrappers → native `.sheet` / `.fullScreenCover`.
10. Replace `RuulCard` / `RuulActionableCard` / `RuulInfoCard` / `RuulMetricCard` → `Section { Row }` inside `List` / `Form`.
11. Replace `EmptyStateView` / `ErrorStateView` → `ContentUnavailableView`.
12. Replace `ModalSheetTemplate` / `MainAppScreenTemplate` / `DetailScreenTemplate` → inline native containers.

### Wave 3 — Vocabulary + structural redesign (UX change, copy review)

PRs 13-N, one per flow:

13. `GovernanceView` rebuild as `Form` with native pickers, renamed to "Decisiones del grupo" or similar.
14. `MyLedgerView` audit: rename to "Mis movimientos" + sweep deeplink IDs.
15. `ResourceWizardSheet` audit: surface concrete actions ("Crear evento", "Crear fondo") instead of abstract "resource" picker.
16. `CapabilityBlockView`, `EditRightSheet`: rename UI labels.
17. **Resource Detail tab restructure** to canonical tabs: Overview / People / Money / Rules / Activity (per doctrine, deliverable C). Highest-impact UX change.
18. Onboarding flow audit (largest unfamiliar surface for new users — first impression).
19. Home screen + Group home as native `List` + `Section`.

### Out of scope

- Backend changes
- Ontology rewrites
- Capability removal internally
- New features
- Settings beyond removing custom chrome

---

## 9. Resolved decisions (founder, 2026-05-19)

All five open questions answered. Doctrine locked-in:

1. **Inter → San Francisco: TOTAL replacement.** No hybrid, no headers-only, no fallback. The single most powerful aesthetic change in the refactor. Strip Inter from `Info.plist`'s `UIAppFonts`, delete `InterVariable.ttf`, replace every `.font(.custom("InterVariable", ...))` with system styles.

2. **Brand wordmark** (`RuulTypography.wordmark`, 88pt) retained ONLY in: onboarding, splash, marketing, login/welcome. **Removed entirely from the product proper.** Inside the app: navigation > branding.

3. **One accent color, period.** Canonical: `.tint(.accentColor)`. Delete `Color.ruulAccentSecondary`, `.ruulAccentSubtle`, semantic-brand-rainbow variants. Pick one global Apple-ish blue (deep, unsaturated). Color should come from content / avatars / symbols / status semantics — NOT from structure.

4. **Group-color theming radically reduced.** Keep ONLY: avatars, tiny accents, event dots, small chips, maybe calendar identity. DELETE: tinted screens, per-group backgrounds, gradients, ambient color dominance. `RuulCoverPalette` + `ruulAmbientScreen` modifier go away. Cover photos as `Image` still allowed if uploaded by users; programmatic palette gradients out.

5. **`.glassEffect()` kept but very controlled.** Use ONLY: floating toolbar, bottom action surfaces, transient overlays, media-like chrome, compact controls over content. NEVER on: every card, every sheet, backgrounds, giant glass panels, dashboard translucency. Audit every `.ruulGlass()` / `.glassEffect()` call site — most are likely on cards/sheets and need to go.

## 9.1 Founder direction (verbatim, doctrine)

> "Delete custom UI aggressively. Prefer native over clever. Prefer calm over expressive. Prefer clarity over uniqueness."

> "No conviertan RuulUI en otro design system enterprise. Conviértanlo en thin wrappers around Apple-native behavior."

### Operational reading

RuulUI exists going forward as **thin wrappers around Apple-native behavior** — never replacements. If a native primitive can do it, USE THE NATIVE PRIMITIVE. RuulUI should shrink from 89 files to a much smaller core (~15-20 files) holding domain wrappers only: `RuulAvatar`, `RuulMoneyView`, `RuulOTPInput`, `RuulPhoneField`, maybe `RuulPersonAvatar`/`RuulGroupAvatar`, and a handful of tokenized helpers. Everything else goes.

This sharpens the priorities in §8: Wave 1 (typography + colors) is still first, but Wave 2's deletions become more aggressive — most of the 41 primitives get DELETED, not refactored.

---

## 10. Deliverables status

- ✅ **A — Apple Native UI Audit** (this doc)
- ⏸️ **B — Design System Simplification Plan**: next session. Will produce a concrete delete/keep/wrap decision per RuulUI file, plus a typography/color migration mapping table.
- ⏸️ **C — Canonical Component Map**: next session. One canonical pattern per primitive (List, Form, Menu, Sheet, TabView, Toolbar, NavigationStack, EmptyState, Search, Activity Feed, ConfirmationDialog).
- ⏸️ **D — Human Layer Rules**: next session. Glossary of banned → allowed words; when sheet vs tab vs menu; empty state template.

After A-D are done, **Wave 1 PR #1** (typography migration) becomes the first concrete refactor.
