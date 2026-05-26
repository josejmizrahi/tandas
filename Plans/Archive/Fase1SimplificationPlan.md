# FASE 1 — Design System Simplification Plan (Deliverable B)

**Status**: Plan-only, written 2026-05-19. No code touched yet.
**Scope**: `ios/Packages/RuulUI/Sources/RuulUI/` (88 Swift files).
**Source of truth**: `Plans/Active/Fase1NativeAudit.md` + memory doctrine
`fase1_native_refactor_doctrine.md`.

---

## 0. Doctrine recap (canon — copy carefully)

> "Delete custom UI aggressively. Prefer native over clever. Prefer calm
> over expressive. Prefer clarity over uniqueness."
>
> "Thin wrappers around Apple-native behavior — never replacements."

RuulUI shrinks from **88 files → ~18 files** keeping only domain
wrappers + a handful of layout primitives. Everything else is replaced
with Apple-native primitives at the call site.

## 0.1 Five locked-in decisions (verbatim — no re-litigation)

1. **Inter → San Francisco TOTAL.** Strip `InterVariable.ttf` + `UIAppFonts`.
2. **Wordmark 88pt ONLY** in splash / onboarding / welcome / login. Banned
   from the rest of the app.
3. **ONE `.tint(.accentColor)`**, deep unsaturated Apple-ish blue. Delete
   accentSecondary / accentSubtle / brand rainbow.
4. **Group color → avatars, dots, tiny chips only.** Delete
   `ruulAmbientScreen`, `RuulMeshBackground`, `RuulAmbientBackground`,
   `RuulCoverPalette`.
5. **`.glassEffect()` only on:** floating toolbar, bottom action surfaces,
   transient overlays, media chrome, compact controls over content.
   Banned from cards/sheets/backgrounds/dashboards.

---

## 1. Decision categories

| Decision | Meaning |
|---|---|
| **DELETE** | Remove the file. Replace every call site with native primitive. |
| **WRAP** | Keep file as a thin wrapper around native behavior. Strip custom chrome (custom backgrounds, spring animations, glass effects). |
| **KEEP_DOMAIN** | Keep file because it encapsulates a real domain concern (money formatting, OTP, phone, avatars). Audit internals for token use, but the abstraction itself stays. |
| **INSPECT_FIRST** | Per-file investigation required before final call. Likely DELETE but call-site count + actual usage in app needs to be verified during PR. |

Each file gets exactly one decision + a target wave.

| Wave | Theme | What lands |
|---|---|---|
| **Wave 1** | Mechanical token migration | Typography → SF / Color → semantic / Motion+Shadow tokens deleted |
| **Wave 2** | Primitive replacement | DELETEs above, native primitive at each call site |
| **Wave 3** | Vocabulary + structural redesign | UI copy, Universal Resource Detail layered scroll (NOT tabs — see `Fase1ComponentMap.md` §"Universal Resource Detail"), GovernanceView, MyLedger, ResourceWizard |

---

## 2. Per-file decision matrix

### 2.1 Tokens (`RuulUI/Tokens/`)

| Path | Category | Decision | Replacement | Reason | Wave |
|---|---|---|---|---|---|
| `Tokens/RuulTypography.swift` | Tokens | **DELETE** | SwiftUI `Font.body/.headline/.title/.title2/.caption/.footnote/.largeTitle` | Inter font is the single largest aesthetic divergence from Apple apps. SF Pro is the only native typography per doctrine. | 1 |
| `Tokens/RuulTypography+DSAliases.swift` | Tokens | **DELETE** | n/a | Aliases to a deleted token. | 1 |
| `Tokens/RuulColors.swift` | Tokens | **DELETE** | `.primary`, `.secondary`, `Color(.systemBackground)`, `Color(.systemGroupedBackground)`, `Color(.separator)`, `.tint`, `.green/.red/.orange/.blue` | 25+ aliases to a Slate/HC palette replicate what UIKit already adapts. Doctrine: semantic system colors only. | 1 |
| `Tokens/RuulColors+DSAliases.swift` | Tokens | **DELETE** | n/a | Aliases to a deleted token. | 1 |
| `Tokens/ResourceFamilyTint+Color.swift` | Tokens | **KEEP_DOMAIN** | n/a — but reduce surface | Per-resource-type tint (event = blue, fund = green, etc.) is a legitimate domain concern shown via avatars/dots/chips per decision #4. Keep but audit that it's not also driving ambient backgrounds. | 2 |
| `Tokens/RuulSpacing.swift` | Tokens | **KEEP_DOMAIN** | n/a | A 4pt grid is doctrinally fine; what matters is that we don't fight `Form`/`List` natural padding. Keep for ad-hoc layouts. | — |
| `Tokens/RuulSpacing+DSAliases.swift` | Tokens | **DELETE** | n/a | DSAlias indirection adds no value. | 1 |
| `Tokens/RuulRadius.swift` | Tokens | **DELETE** | inline `RoundedRectangle(cornerRadius: 10)` or rely on `Section` | Three radius values used inconsistently; native containers come with their own corner radii. | 2 |
| `Tokens/RuulRadius+DSAliases.swift` | Tokens | **DELETE** | n/a | — | 1 |
| `Tokens/RuulShadow.swift` | Tokens | **DELETE** | n/a | File is already a tombstone (just a comment redirecting to RuulElevation). | 1 |
| `Tokens/RuulElevation.swift` | Tokens | **DELETE** | n/a — no replacement | Apple uses materials + separators, not shadows. Doctrine bans shadow chrome. | 1 |
| `Tokens/RuulMotion.swift` | Tokens | **DELETE** | `.default` / `.smooth` / native sheet+nav transitions | Custom spring presets violate "subtle native motion only". | 1 |
| `Tokens/RuulMotion+DSAliases.swift` | Tokens | **DELETE** | n/a | — | 1 |
| `Tokens/RuulHaptics.swift` | Tokens | **KEEP_DOMAIN** | n/a | `.sensoryFeedback(...)` semantic mapping (`.selection`, `.light`, `.success`) is fine; it's a thin wrapper around the native API. Audit any custom feedback types. | 2 |
| `Tokens/RuulGlass.swift` | Tokens | **WRAP** | thin enum wrapping `Glass` material | Only used by `GlassEffect+Ruul`. Keep as part of the glass-effect wrapper; do not expose elsewhere. | 2 |
| `Tokens/RuulOpacity.swift` | Tokens | **INSPECT_FIRST** | inline opacities | If it's `(.low, .medium, .high)` only, delete and inline. Keep only if it carries semantic meaning (e.g. "disabled tile dim"). | 2 |
| `Tokens/RuulSize.swift` | Tokens | **INSPECT_FIRST** | inline sizes | Same — if it's just constants for icon sizes/touch targets, fold into call sites. | 2 |

### 2.2 Theme (`RuulUI/Theme/`)

| Path | Category | Decision | Replacement | Reason | Wave |
|---|---|---|---|---|---|
| `Theme/RuulTheme.swift` | Theme | **DELETE** | n/a | `@Environment(\.ruulColors)` indirection becomes pointless once we're on semantic system colors. | 2 |
| `Theme/ColorScheme+Ruul.swift` | Theme | **INSPECT_FIRST** | likely DELETE | If it's just `.preferredColorScheme` helpers, replace with native. If it manages high-contrast trait, may delete (UIKit traits already feed system colors). | 2 |
| `AppearanceOption.swift` (root) | Theme | **KEEP_DOMAIN** | n/a | Likely the user-facing "Light / Dark / System" preference type. Domain enum, not chrome. Audit. | 2 |

### 2.3 Modifiers (`RuulUI/Modifiers/`)

| Path | Category | Decision | Replacement | Reason | Wave |
|---|---|---|---|---|---|
| `Modifiers/GlassEffect+Ruul.swift` | Modifiers | **WRAP** | thin wrapper over `.glassEffect(_:in:)` | Per decision #5 keep, but tighten use to floating toolbars / bottom bars / transient overlays / media chrome. Rename internal API to discourage "glass everywhere". | 2 |
| `Modifiers/LoadingDebounce.swift` | Modifiers | **KEEP_DOMAIN** | n/a | Debouncing the loading indicator avoids flicker; legit utility. Keep. | — |
| `Modifiers/PressFeedback.swift` | Modifiers | **DELETE** | native `.bordered` / `.borderedProminent` / `.plain` button styles | Custom scale-on-press + opacity-dip duplicates what Apple already does; doctrine says "subtle native only". | 2 |
| `Modifiers/RuulAmbientScreen.swift` | Modifiers | **DELETE** | `Color(.systemGroupedBackground)` or `Color(.systemBackground)` | Per decision #4, ambient mesh screen backgrounds are out. | 2 |
| `Modifiers/RuulCoverPalette.swift` | Modifiers | **INSPECT_FIRST** | `RuulCoverCatalog` only if user-uploaded cover images stay | Cover *photos* (real images) may stay if users upload them. *Palette* / *gradient* covers from a UUID hash are out. Audit which callers use what. Likely DELETE the palette helper, keep the catalog of curated photos if any. | 2 |
| `Modifiers/RuulSheetToolbar.swift` | Modifiers | **DELETE** | native `.toolbar { ToolbarItem(.cancellationAction) { Button("Cancelar") {} }; ToolbarItem(.principal) { Text(title) } }` at each call site | Wraps a 6-line idiom in 1 line, but standardizes a "x + centered title" pattern that's wrong for many sheets (Form sheets use `.navigationTitle` automatically). | 2 |
| `Modifiers/RuulSurfaceStyle.swift` | Modifiers | **DELETE** | n/a | Card chrome — banned per doctrine. | 2 |

### 2.4 Patterns (`RuulUI/Patterns/`)

| Path | Category | Decision | Replacement | Reason | Wave |
|---|---|---|---|---|---|
| `Patterns/AsyncContentView.swift` | Patterns | **WRAP** | keep as a thin if/else around `.task` + phase | Real utility (loading/empty/error phases) but rebuild internals so empty/error use `ContentUnavailableView` natively. | 2 |
| `Patterns/EmptyStateView.swift` | Patterns | **DELETE** | `ContentUnavailableView(title, systemImage:, description:, actions:)` (iOS 17+) | Apple's `ContentUnavailableView` is the canonical pattern — already exactly what we built by hand. | 2 |
| `Patterns/ErrorStateView.swift` | Patterns | **DELETE** | `ContentUnavailableView(_:image:description:actions:)` with system error iconography | Same. | 2 |
| `Patterns/ErrorStateView+CoordinatorError.swift` | Patterns | **DELETE** | n/a — fold into a `View.contentUnavailable(for:)` helper if needed | Helper extension to deleted pattern. | 2 |
| `Patterns/EventCardStub.swift` | Patterns | **INSPECT_FIRST** | likely DELETE | Preview-only stub; may not have callers outside `#Preview`. | 2 |
| `Patterns/FineCardStub.swift` | Patterns | **INSPECT_FIRST** | likely DELETE | — | 2 |
| `Patterns/MemberRowStub.swift` | Patterns | **INSPECT_FIRST** | likely DELETE | — | 2 |
| `Patterns/RuleCardStub.swift` | Patterns | **INSPECT_FIRST** | likely DELETE | — | 2 |
| `Patterns/OnboardingStepContainer.swift` | Patterns | **KEEP_DOMAIN** | n/a | Standardizes onboarding chrome (button + progress + back gesture). Legit pattern; keep but strip custom typography/colors. | 2 |
| `Patterns/RSVPStateView.swift` | Patterns | **KEEP_DOMAIN** | n/a — but rebuild as native | Domain-specific RSVP state UI. Keep, refactor internals to `Section`/`Label`/native chrome. | 3 |
| `Patterns/RuulInlineProgress.swift` | Patterns | **DELETE** | native `ProgressView(value:)` | — | 2 |
| `Patterns/RuulLoadingState.swift` | Patterns | **DELETE** | native `ProgressView()` | — | 2 |
| `Patterns/RuulSeparatedRows.swift` | Patterns | **DELETE** | native `List { Section { ForEach { ... } } }` provides separators | — | 2 |
| `Patterns/TimezonePicker.swift` | Patterns | **KEEP_DOMAIN** | n/a | Timezone search/select is non-trivial; keep but audit internals to use `List` + `.searchable`. | 3 |

### 2.5 Primitives (`RuulUI/Primitives/`)

| Path | Category | Decision | Replacement | Reason | Wave |
|---|---|---|---|---|---|
| `Primitives/ActionCard.swift` | Primitives | **DELETE** | `Section { Button { ... } }` row inside `List`/`Form` | Card metaphor banned. | 2 |
| `Primitives/RuulActionableCard.swift` | Primitives | **DELETE** | `NavigationLink { ... } label: { ... }` row | — | 2 |
| `Primitives/RuulAmbientBackground.swift` | Primitives | **DELETE** | n/a | Mesh gradient backgrounds banned per decision #4. | 2 |
| `Primitives/RuulMeshBackground.swift` | Primitives | **DELETE** | n/a | — | 2 |
| `Primitives/RuulAvatar.swift` | Primitives | **KEEP_DOMAIN** | n/a | Profile photo with initials fallback — no native equivalent. Keep, switch initials text to system font. | 2 |
| `Primitives/RuulAvatarStack.swift` | Primitives | **KEEP_DOMAIN** | n/a | Stacked avatar group ("+3"). Keep. | 2 |
| `Primitives/RuulPersonAvatar.swift` | Primitives | **KEEP_DOMAIN** | n/a | Person-specialized avatar wrapper. Audit for redundancy with `RuulAvatar`; merge if duplicative. | 2 |
| `Primitives/RuulGroupAvatar.swift` | Primitives | **KEEP_DOMAIN** | n/a | Group-specialized avatar wrapper. Same audit. | 2 |
| `Primitives/RuulGroupComponents+Group.swift` | Primitives | **INSPECT_FIRST** | likely WRAP | Group-domain extensions on RuulCore.Group from UI side. Audit for doctrinal drift; group chrome should live in features, not UI. | 2 |
| `Primitives/RuulGroupSwitcher.swift` | Primitives | **WRAP** | rebuild as a `Menu` or `Button { sheet }` with system chrome | Domain UI (switch active group) is legit; current rendering uses glass pill + custom typography. | 3 |
| `Primitives/RuulBadge.swift` | Primitives | **DELETE** | `Text(...).font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.tint.opacity(0.15), in: .capsule)` inlined, or native `.badge(_:)` modifier on list rows | A status capsule isn't a primitive worth maintaining — Apple's `.badge(...)` modifier on tabs / list rows is the canonical pattern for counts. For inline tags, inline the styling. | 2 |
| `Primitives/RuulIconBadge.swift` | Primitives | **DELETE** | `Image(systemName:).font(.title3).foregroundStyle(.tint).frame(width: 44, height: 44)` inlined; do not glass-circle every icon | Glass-circle icon badges are decorative chrome. Apple uses bare `Image(systemName:)` inside lists/empty-states. | 2 |
| `Primitives/RuulButton.swift` | Primitives | **WRAP** | thin wrapper that picks `.borderedProminent` (primary) / `.bordered` (secondary) / `.glass` (when over content) / `.plain` / role: `.destructive` + exposes `isLoading` | Centralizing loading-indicator + haptic semantics is legit; the current `Capsule().fill(Color.ruulAccent) + .ruulElevation` chrome is not. Strip all custom backgrounds. | 2 |
| `Primitives/RuulCard.swift` | Primitives | **DELETE** | `Section { rows }` inside `List`/`Form`; if truly free-form, `GroupBox` or inline `RoundedRectangle` | Card metaphor banned. | 2 |
| `Primitives/RuulInfoCard.swift` | Primitives | **DELETE** | `Section { Label(...); Text(...) }` or `GroupBox` | — | 2 |
| `Primitives/RuulMetricCard.swift` | Primitives | **DELETE** | `LabeledContent("label") { Text("$1,200").font(.title) }` in a `Section`, or hero `Text(...).font(.largeTitle).bold()` over a `Section` header for balance views | Dashboard metric tiles are a SaaS pattern. | 2 |
| `Primitives/TemplatePickerCard.swift` | Primitives | **DELETE** | `List { Section { ForEach(templates) { NavigationLink { ... } label: { Label(t.title, systemImage: t.symbol) } } } }` | Card metaphor + bespoke chrome; native list row covers the use case. | 3 |
| `Primitives/RuulChip.swift` | Primitives | **DELETE** | filter UI: `Picker(.segmented)` or `Menu`; tags inline as `Text + .background(.tint.opacity(0.15), in: .capsule)` | Custom chip primitive collides with native segmented control + Menu. | 2 |
| `Primitives/RuulCloseToolbarButton.swift` | Primitives | **DELETE** | `Button { dismiss() } label: { Image(systemName: "xmark") }` inside `ToolbarItem(placement: .topBarLeading)` | One-liner native. | 2 |
| `Primitives/RuulCoverCatalog.swift` | Primitives | **INSPECT_FIRST** | likely KEEP_DOMAIN as photo catalog only | If `RuulCover` is a curated photo catalog, keep — user-uploaded covers are still allowed. If it's only programmatic palette gradients, DELETE. | 2 |
| `Primitives/RuulDatePicker.swift` | Primitives | **DELETE** | `DatePicker("label", selection: ..., displayedComponents: ...)` | If thin, just delete and inline; if heavy custom UI, the heavy parts violate doctrine. | 2 |
| `Primitives/RuulFullScreenCover.swift` | Primitives | **DELETE** | `.fullScreenCover(isPresented:)` directly | Native one-liner. | 2 |
| `Primitives/RuulSheet.swift` | Primitives | **DELETE** | `.sheet(isPresented:) { NavigationStack { ... } }` for partial; `.fullScreenCover(isPresented:)` for takeover | Wraps native with policy comment that should live in this doc instead. Decision: most sheets become `.sheet` with `.presentationDetents([.medium, .large])`; only true takeover flows (full-screen wizard, camera) use `.fullScreenCover`. **Note**: this reverses the 2026-05-15 "every modal is fullScreenCover" policy — see Open Questions §6. | 2 |
| `Primitives/RuulHeaderActions.swift` | Primitives | **DELETE** | `.toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button {} ... } }` | Glass pill grouping toolbar buttons; native toolbar already groups them. | 2 |
| `Primitives/RuulInlineActionBar.swift` | Primitives | **DELETE** | inline native: `HStack { Button(.bordered)/.glassEffect() } ` for 2-3 actions; or `.toolbar { ToolbarItemGroup(placement: .bottomBar) }` ; for many actions, push to `swipeActions` / context menus / a `Menu` | Custom tile bar — see also Universal Resource Detail layered rebuild (wave 3); many of its actions move to toolbar / context menus / the Coordination block's own inline CTAs. See `Fase1ComponentMap.md` §"Universal Resource Detail". | 3 |
| `Primitives/RuulInlineMessage.swift` | Primitives | **DELETE** | inline error → `Section { } footer: { Text(error).foregroundStyle(.red) }`; success → silent (the new row appears); warning → inline `Label("...", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)` in a `Section` | Tinted info/success/warning/error banner — doctrine-incompatible "toast-y" pattern. | 2 |
| `Primitives/RuulListSectionHeader.swift` | Primitives | **DELETE** | `Section("Title") { ... }` or `Section { ... } header: { Text("Title").font(.footnote).foregroundStyle(.secondary) }` | `List` provides section headers natively. | 2 |
| `Primitives/RuulMoneyView.swift` | Primitives | **KEEP_DOMAIN** | n/a | Money formatting is a domain concern (locale, currency, sign). Keep, ensure it uses system typography. | 2 |
| `Primitives/RuulOTPInput.swift` | Primitives | **KEEP_DOMAIN** | n/a | OTP entry has specific keyboard + autofill semantics. Justified custom UI. Audit for `.textContentType(.oneTimeCode)` compliance. | — |
| `Primitives/RuulPhoneField.swift` | Primitives | **KEEP_DOMAIN** | n/a | Phone formatting + country code is non-trivial. Keep. | — |
| `Primitives/RuulOriginTag.swift` | Primitives | **INSPECT_FIRST** | likely DELETE | Domain-specific tag (event origin, host badge). If it's just a styled pill, inline; if it carries logic, keep. | 2 |
| `Primitives/RuulPicker.swift` | Primitives | **DELETE** | native `Picker(selection:) { ForEach { Text(label).tag(value) } }.pickerStyle(.menu/.wheel/.inline)` | Custom radio-list picker with glass + spring violates "native segmented controls / pickers". | 2 |
| `Primitives/RuulPillButton.swift` | Primitives | **DELETE** | toolbar buttons: `Button {} label: { Image(systemName: ...) }` inside `ToolbarItem`; over-content: `Button {}.buttonStyle(.glass)` (iOS 26 native style) | Glass circular pill; iOS 26 ships `.glassEffect()` natively. | 2 |
| `Primitives/RuulProgressBar.swift` | Primitives | **DELETE** | `ProgressView(value: 0.5)` with linear style | — | 2 |
| `Primitives/RuulQuietActionBar.swift` | Primitives | **INSPECT_FIRST** | likely DELETE | Variant of `RuulInlineActionBar`; same fate. | 3 |
| `Primitives/RuulSegmentedControl.swift` | Primitives | **DELETE** | `Picker(selection:) { ... }.pickerStyle(.segmented)` | Custom glass+spring segmented control violates "native segmented controls". | 2 |
| `Primitives/RuulTabBar.swift` | Primitives | **DELETE** | `TabView { ...tabItem... }.tabViewStyle(.tabBarOnly)` (or default), `.tabBarMinimizeBehavior(.onScrollDown)` | Custom floating glass tab bar; iOS 26 `TabView` renders Liquid Glass natively. | 2 |
| `Primitives/RuulTextField.swift` | Primitives | **INSPECT_FIRST** | likely **WRAP** as `TextField` style + label | If it's a `TextField` with a leading label and consistent height, keep as thin wrapper. If it imposes custom background/border, strip and use `.textFieldStyle(.roundedBorder)` / `.plain` inside a `Section`. | 2 |
| `Primitives/RuulTimelineItem.swift` | Primitives | **KEEP_DOMAIN** | n/a — but rebuild internals | Activity timeline row is a real Ruul-specific pattern (see Activity Feed in Component Map). Keep, refactor to native typography + `Label` + `Text` chrome. | 3 |
| `Primitives/RuulToast.swift` | Primitives | **DELETE** | errors → `.alert(...)`; success → no notification (the new row appears in the list); info → inline `Section` footer | "Top banner auto-dismiss" violates doctrine ban on custom toast systems. | 2 |
| `Primitives/RuulToggle.swift` | Primitives | **DELETE** | `Toggle("label", isOn: $value)` | If it adds business logic, refactor that out of the toggle. | 2 |

### 2.6 Templates (`RuulUI/Templates/`)

| Path | Category | Decision | Replacement | Reason | Wave |
|---|---|---|---|---|---|
| `Templates/MainAppScreenTemplate.swift` | Templates | **DELETE** | `NavigationStack { ... }` inline per screen | App-screen templating belongs in the feature, not the design system. | 2 |
| `Templates/DetailScreenTemplate.swift` | Templates | **DELETE** | `NavigationStack { Form { ... } }` or `List { ... }` inline | — | 2 |
| `Templates/ModalSheetTemplate.swift` | Templates | **DELETE** | `.sheet { NavigationStack { Form { ... }.navigationTitle(...).toolbar { ... } } }` per call site | — | 2 |
| `Templates/OnboardingScreenTemplate.swift` | Templates | **KEEP_DOMAIN** | n/a | Standardizes onboarding chrome (back gesture + progress + bottom button). Keep but rebuild to use system typography. | 2 |
| `Templates/ResourceTabBar.swift` | Templates | **DELETE** | native `TabView { ...tabItem... }.tabBarMinimizeBehavior(.onScrollDown)` inline | Already a thin wrapper over `TabView` + `.badge(...)`. The thin wrapper saves no real complexity; inline the 5 lines. | 2 |

### 2.7 Resources (`RuulUI/Resources/`)

| Path | Category | Decision | Replacement | Reason | Wave |
|---|---|---|---|---|---|
| `Resources/ResourceAction.swift` | Resources | **KEEP_DOMAIN** | n/a | Domain enum modeling resource actions. Stays. | — |
| `Resources/ResourceActionsProvider.swift` | Resources | **KEEP_DOMAIN** | n/a | Domain protocol/provider. Stays — but caller-side UI changes per Resource Detail rebuild (wave 3). | — |

### 2.8 Root

| Path | Category | Decision | Replacement | Reason | Wave |
|---|---|---|---|---|---|
| `AppearanceOption.swift` | Theme | **KEEP_DOMAIN** | n/a | User preference for color scheme. Stays. | — |
| `CONVENTIONS.md` | Docs | **KEEP** | rewrite for new doctrine | Conventions doc — rewrite at end of FASE 1 to match new state. | 3 |

---

## 3. Survivors — what RuulUI looks like at end of FASE 1

Target end state: **~18 files**, all of them either (a) domain wrappers
no native primitive can replace, or (b) genuinely thin layout
utilities.

```
RuulUI/Sources/RuulUI/
├── AppearanceOption.swift
├── CONVENTIONS.md (rewritten)
├── Modifiers/
│   ├── GlassEffect+Ruul.swift   (constrained usage)
│   └── LoadingDebounce.swift
├── Patterns/
│   ├── AsyncContentView.swift   (rebuilt internals)
│   ├── OnboardingStepContainer.swift
│   ├── RSVPStateView.swift      (rebuilt internals)
│   └── TimezonePicker.swift     (rebuilt internals)
├── Primitives/
│   ├── RuulAvatar.swift
│   ├── RuulAvatarStack.swift
│   ├── RuulPersonAvatar.swift
│   ├── RuulGroupAvatar.swift
│   ├── RuulGroupSwitcher.swift  (rebuilt internals)
│   ├── RuulButton.swift          (thin .borderedProminent/.bordered/.glass wrapper)
│   ├── RuulMoneyView.swift
│   ├── RuulOTPInput.swift
│   ├── RuulPhoneField.swift
│   ├── RuulTextField.swift       (thin label wrapper, if kept)
│   └── RuulTimelineItem.swift    (rebuilt internals)
├── Resources/
│   ├── ResourceAction.swift
│   └── ResourceActionsProvider.swift
├── Templates/
│   └── OnboardingScreenTemplate.swift
└── Tokens/
    ├── ResourceFamilyTint+Color.swift
    ├── RuulHaptics.swift
    ├── RuulSpacing.swift         (4pt grid for ad-hoc layouts only)
    └── RuulGlass.swift           (private to GlassEffect+Ruul if possible)
```

Net deletion: **88 → ~22 files (~75% shrinkage)**.

---

## 4. Migration tables

### 4.1 Typography migration (Wave 1, PR #1)

**Scope**: every `.ruulTextStyle(RuulTypography.X)` + every
`.font(.ruulX)` call site across all 143 feature files + RuulUI itself.

**Mapping** (canonical — apply mechanically):

| RuulTypography token | SwiftUI replacement | Notes |
|---|---|---|
| `RuulTypography.wordmark` (88pt) | **Keep only in splash/onboarding/welcome/login.** Inside the app, DELETE the call site entirely. | Per decision #2. |
| `RuulTypography.displayHero` (54pt) | `.font(.system(size: 54, weight: .bold))` in splash/onboarding only; elsewhere `.largeTitle.bold()` | Apple's largest type is `.largeTitle` (~34pt). Display sizes only make sense on splash. |
| `RuulTypography.displayLarge` (44pt) | `.largeTitle.bold()` (splash/onboarding); inside app, `.title.bold()` | — |
| `RuulTypography.displayMedium` (34pt) | `.largeTitle.weight(.semibold)` or `.title.bold()` | — |
| `RuulTypography.titleLarge` (28pt semibold) | `.title.weight(.semibold)` | — |
| `RuulTypography.title` (22pt semibold) | `.title2.weight(.semibold)` | — |
| `RuulTypography.titleMedium` (22pt medium) | `.title2.weight(.medium)` | — |
| `RuulTypography.headline` (18pt semibold) | `.headline` | — |
| `RuulTypography.headlineMedium` (18pt medium) | `.headline.weight(.medium)` | Rare; verify need before mapping. |
| `RuulTypography.subhead` (16pt regular) | `.subheadline` (15pt) — close enough; or `.body` (17pt) when used as primary row label | Edge case: see Open Questions §1. |
| `RuulTypography.subheadSemibold` (16pt semibold) | `.subheadline.weight(.semibold)` or `.body.weight(.semibold)` | Edge case: see Open Questions §1. |
| `RuulTypography.subheadMedium` (16pt medium) | `.subheadline.weight(.medium)` | — |
| `RuulTypography.subheadBold` (16pt bold) | `.subheadline.weight(.bold)` | — |
| `RuulTypography.bodyLarge` (17pt regular) | `.body` | `.body` is 17pt at default Dynamic Type. |
| `RuulTypography.body` (15pt regular) | `.subheadline` (15pt) | — |
| `RuulTypography.callout` (14pt medium) | `.callout` (16pt) or `.footnote` (13pt) | Edge case: see Open Questions §1. |
| `RuulTypography.calloutRegular` (14pt regular) | `.callout` or `.footnote` | — |
| `RuulTypography.calloutBold` (14pt bold) | `.callout.weight(.bold)` or `.footnote.weight(.bold)` | — |
| `RuulTypography.labelSemibold` (14pt semibold) | `.footnote.weight(.semibold)` | — |
| `RuulTypography.labelSmSemibold` (13pt semibold) | `.footnote.weight(.semibold)` | — |
| `RuulTypography.caption` (12pt medium, +tracking) | `.caption` (12pt) | Drop the custom tracking. |
| `RuulTypography.captionBold` | `.caption.weight(.bold)` | — |
| `RuulTypography.captionSemibold` | `.caption.weight(.semibold)` | — |
| `RuulTypography.footnote` (11pt uppercase, +tracking) | `.footnote` | **Drop uppercase** — that's a SaaS pattern. Apple lists don't uppercase section headers (`List` does it itself if needed). |
| `RuulTypography.sectionLabel` (11pt mono uppercase bold) | `.footnote.weight(.semibold).foregroundStyle(.secondary)` inside `Section { } header:` — let `List` provide chrome | — |
| `RuulTypography.sectionLabelLg` (13pt mono uppercase bold) | same as above | — |
| `RuulTypography.microSemibold` (11pt semibold) | `.caption2.weight(.semibold)` | `.caption2` is 11pt. |
| `RuulTypography.microBold` (10pt bold) | `.caption2.weight(.bold)` | — |
| `RuulTypography.mono` (14pt mono regular) | `.body.monospaced()` | iOS 16+ has `.monospaced()` modifier. |
| `RuulTypography.monoLarge` (24pt mono semibold) | `.title2.monospaced().weight(.semibold)` | — |
| `RuulTypography.statSmall` (13pt mono bold) | `.footnote.monospacedDigit().weight(.bold)` | Numbers only: prefer `.monospacedDigit()` over full `.monospaced()`. |
| `RuulTypography.statMedium` (17pt mono bold) | `.body.monospacedDigit().weight(.bold)` | — |
| `RuulTypography.statHero` (48pt mono heavy) | `.largeTitle.monospacedDigit().weight(.heavy)` | — |
| `RuulTypography.bulletDot` (4pt) | inline `Text("•").font(.caption2).foregroundStyle(.tertiary)` | — |

**Example before/after**:

```swift
// BEFORE — HomeView.swift line 64 (illustrative)
Text("Pendientes")
    .ruulTextStyle(RuulTypography.footnote)
    .foregroundStyle(Color.ruulTextSecondary)

// AFTER
Text("Pendientes")
    .font(.footnote)
    .foregroundStyle(.secondary)
// (And ideally: lifted into Section("Pendientes") { ... } where it
// gets a native, properly-styled section header for free.)
```

```swift
// BEFORE — WelcomeView.swift line 16
Text("Bienvenido a ruul")
    .ruulTextStyle(RuulTypography.displayLarge)
    .foregroundStyle(Color.ruulTextPrimary)

// AFTER (splash context — allowed)
Text("Bienvenido a ruul")
    .font(.largeTitle.bold())
    .foregroundStyle(.primary)
```

**Scope estimate**: ~3,045 total token references in features (per audit
§1) — typography accounts for ~40% of those = **~1,200 call sites**.
Single mechanical PR.

**Edge cases**:
- 14pt `callout` ↔ Apple's `.callout` (16pt) ↔ `.footnote` (13pt): pick
  based on context. As row labels (`14pt medium`) usually closer to
  `.footnote`. As button labels, closer to `.body`. **See Open
  Questions §1**.
- 16pt `subhead` ↔ Apple's `.subheadline` (15pt) ↔ `.body` (17pt):
  prefer `.subheadline` when used as secondary; `.body` when primary.
- Uppercase footnote: drop the `.textCase(.uppercase)` everywhere —
  Apple lists don't uppercase headers; `Section` does it itself if/when
  appropriate.
- Mono cuts: replace with `.monospacedDigit()` for numbers, `.monospaced()`
  for full mono. `.monospacedDigit()` keeps SF Pro letterforms and
  switches only the digit cuts — usually what we want.

### 4.2 Color migration (Wave 1, PR #2-3)

| RuulColors token | SwiftUI replacement | Context-dependent |
|---|---|---|
| `Color.ruulTextPrimary` | `.primary` | always |
| `Color.ruulTextSecondary` | `.secondary` | always |
| `Color.ruulTextTertiary` | `.tertiary` (iOS 17+) or `Color(.tertiaryLabel)` | always |
| `Color.ruulTextInverse` | `Color.white` over dark surfaces, `Color.black` over light surfaces — usually `.primary` with foregroundStyle on .accent | inverse-on-tint is rare; case by case |
| `Color.ruulTextAccent` | `.tint` (in toolbar/links) — usually we can DELETE this and let SwiftUI's link/button tinting do it | |
| `Color.ruulAccent` / `Color.ruulAccentPrimary` | `.tint` or `Color.accentColor` | The app-wide accent comes from the Asset Catalog `AccentColor` set; views should use `.tint(.accentColor)` from a single root and not pass it inline. Per decision #3, pick ONE Apple-ish deep blue and set it there. |
| `Color.ruulAccentSecondary` | DELETE — replace with `.secondary` or contextual content color | decision #3 |
| `Color.ruulAccentSubtle` / `Color.ruulAccentMuted` | inline `Color.accentColor.opacity(0.15)` | decision #3 — and only used as fills on tags/chips, which are mostly going away |
| `Color.ruulBackground` / `Color.ruulBackgroundCanvas` | `Color(.systemBackground)` when on detail screen; `Color(.systemGroupedBackground)` when on List | context-aware |
| `Color.ruulBackgroundElevated` | `Color(.secondarySystemBackground)` (rows in list) or unset (List provides) | usually unset |
| `Color.ruulBackgroundRecessed` | `Color(.systemGroupedBackground)` | usually unset |
| `Color.ruulSurface` / `Color.ruulSurfaceSecondary` | DELETE — use `Section` row instead of fill | most call sites disappear when we move to List |
| `Color.ruulSeparator` / `Color.ruulSeparatorOpaque` | `Color(.separator)` | rare — List provides separators |
| `Color.ruulBorderSubtle/Default/Strong` | DELETE — borders are a SaaS tell. Native uses materials/separators | — |
| `Color.ruulPositive` | `.green` or `Color(.systemGreen)` | foreground only |
| `Color.ruulNegative` | `.red` or `Color(.systemRed)` | foreground only |
| `Color.ruulWarning` | `.orange` or `Color(.systemOrange)` | foreground only |
| `Color.ruulInfo` | `.blue` or `Color(.systemBlue)` | foreground only |
| `Color.ruulPositiveBackground` / `.ruulNegativeBackground` etc. | inline `.green.opacity(0.15)` | most usages disappear when we delete `RuulBadge`/`RuulInlineMessage` |
| `Color.ruulSurfaceGlassThin/Regular/Thick` | DELETE — `.glassEffect()` handles glass | — |
| `Color.ruulFillGlass/Strong` | DELETE — inline `Color(.tertiarySystemFill)` if needed | — |
| `Color.ruulOverlayDim` | `.black.opacity(0.35)` — native sheets handle their own scrim | rare |
| `Color.ruulOverlayHighlight` | DELETE | decorative glow over textured surfaces — not allowed per decision #4 |
| `Color.ruulOnImage` / `ruulOnImageSecondary` / `ruulOnImageInverse` | `.white` / `.white.opacity(0.85)` / `.black` | image-overlay text — kept inline, no token needed |
| `Color.ruulImageBadge` / `ruulImagePill*` | inline `.black.opacity(0.55)` etc. | rare |
| `Color.ruulImageVignetteMid/Deep` | inline | rare |
| `Color.ruulImageTextShadow` | inline | rare |
| `Color.ruulCameraBackground` | `.black` | OTP/camera screen |
| `RuulColors.default.meshCool / meshViolet / meshAqua` | DELETE entirely | decision #4 |

**Accent color setup** (decision #3):
- Asset Catalog: define one `AccentColor` set with light + dark
  variants. Deep unsaturated blue. Example values to pick from:
  `#3F6BCC` light / `#7AA0EE` dark.
- App root applies `.tint(.accentColor)` once. Views must NOT override.
- Anywhere we currently pass `.tint(Color.ruulAccent)` or
  `.foregroundStyle(Color.ruulAccent)`: drop the explicit arg, let
  inherited tint apply.

**Example before/after**:

```swift
// BEFORE
HStack { /* ... */ }
    .padding(RuulSpacing.md)
    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
    .ruulElevation(.sm)

// AFTER
// Move into a List + Section:
Section { /* the rows that used to live inside the card */ }
// Done. No padding, no fill, no radius, no shadow.
```

**Scope estimate**: ~25% of the 3,045 token references = **~760 color
calls**. Some are mechanical, ~30% need context decision (`ruulSurface`
→ list row vs `.secondarySystemBackground` vs delete). 2-3 PRs.

**Edge cases**:
- `ruulTextInverse`: when used over `.ruulAccent` background as a primary
  button label, replace with default `.tint` foreground (filled
  `.borderedProminent` button handles inverse text itself).
- `ruulSurface` inside `RuulCard`: gone, since `RuulCard` itself is
  deleted. Where free-form surfaces survive (rare), use
  `Color(.secondarySystemBackground)`.
- High-contrast variants: `.primary`/`.secondary` already adapt to
  high-contrast trait automatically; no manual HC handling needed.

### 4.3 Spacing migration (Wave 1, PR #4 — partial)

Keep `RuulSpacing.swift` (4pt grid). The migration is "where to use it":

| Use site | Old | New | Rationale |
|---|---|---|---|
| Padding inside a `Form` or `List` | `.padding(RuulSpacing.md)` | **REMOVE** — let Form/List native padding apply | Form/List already have correct insets. |
| Section-to-section gap inside a custom `ScrollView { VStack }` | `VStack(spacing: RuulSpacing.s8)` | **Replace** with `Section`s in a `List` (no manual spacing) | When we move screens off ScrollView/VStack onto List, manual gaps go away. |
| Custom hero/empty/onboarding layout (no List) | `VStack(spacing: RuulSpacing.xxl)` | Keep — these are real layout decisions outside the List system. | OK to keep on splash, empty states, onboarding. |
| Min touch target | `RuulSpacing.minTouchTarget` | Keep, use as `.frame(minWidth: 44, minHeight: 44)` | HIG-aligned constant. |

Token aliases (`.xs/.sm/.md/.lg/.xl/.xxl`) → keep numeric tokens
(`.s1`–`.s12`). Most call sites in the codebase use semantic names
(`.lg`, `.xxl`); both APIs may coexist or we consolidate to `.s1-s12`
during this migration. See Open Questions §2.

**Scope estimate**: ~20% of references = ~600 call sites. Most disappear
when the surrounding layout moves to `Form`/`List`. Single PR.

### 4.4 Motion migration (Wave 1, PR #4 — partial)

| Old | New | Rationale |
|---|---|---|
| `withAnimation(.ruulSnappy) { ... }` | `withAnimation { ... }` (default) or `withAnimation(.smooth) { ... }` | Drop the spring, let SwiftUI default. |
| `withAnimation(.ruulSmooth) { ... }` | `withAnimation(.smooth) { ... }` | — |
| `withAnimation(.ruulBouncy) { ... }` | `withAnimation { ... }` | "Bouncy" violates calm. |
| `withAnimation(.ruulMorph) { ... }` | `withAnimation(.smooth) { ... }` | — |
| `.animation(.ruulSnappy, value: ...)` | `.animation(.smooth, value: ...)` or `.animation(.default, value: ...)` | — |
| `.transition(.move(edge: .top).combined(with: .opacity))` (RuulToast) | n/a — toast is deleted | — |
| `matchedGeometryEffect(id:in:)` for custom segmented | n/a — segmented control replaced by `Picker(.segmented)` which has built-in transitions | — |
| `.ruulHaptic(.selection, trigger:)` | `.sensoryFeedback(.selection, trigger:)` (iOS 17+ native) | Native equivalent exists. |

**Scope estimate**: <100 call sites across all features. Single PR.

### 4.5 Shadow / elevation migration (Wave 1, PR #4 — partial)

**All `.ruulElevation(.sm/.md/.lg/.glass)` calls → DELETE.**

Replacement strategy:
- Cards/tiles that need depth → move into `Section` inside `List`. Done.
- Truly floating surfaces (bottom action bar, floating toolbar) → `.glassEffect()` provides the depth via material, no shadow needed.
- Modal sheets / fullScreenCovers → native presentation already provides depth.
- Floating CTAs → none allowed (no FABs per doctrine).

Apple's pattern is **materials over shadows**. Shadows imply
depth-by-light; materials imply depth-by-blur. iOS uses the latter.

**Scope estimate**: ~80 call sites. Single PR; deletes only. No
replacement needed except where `RuulCard.solid` chrome was the only
thing visually grouping a screen (rare).

---

## 5. Inter font removal (Wave 1, PR #5)

Mechanical but cross-package:

1. Delete `Tandas/Resources/Fonts/InterVariable.ttf` (asset).
2. Remove `UIAppFonts` entry from `Tandas/Info.plist` (or generated
   plist).
3. Delete `Font.custom("InterVariable", ...)` references inside
   `RuulTypography.swift` (already deleted via 4.1).
4. Audit `project.yml` for font references → strip.
5. Verify in simulator: every Text view renders in SF.

**Done when**: `grep -rn 'InterVariable\|Inter Variable' ios/` returns 0
hits.

---

## 6. Wave sequencing recap

| Wave | PRs | Theme | Visual delta |
|---|---|---|---|
| **Wave 1** | 1 typography, 2-3 color, 4 spacing+motion+shadow, 5 Inter removal | Mechanical token migration | App switches from Inter+custom palette to SF+system semantic colors. **Biggest perceived delta** per LOC — looks like a different (more Apple-ish) app even with same components. |
| **Wave 2** | 1 per primitive cluster (~10 PRs) | Primitive replacement | Cards become Sections. Custom controls become native pickers/toggles/datepickers/tabbars. Templates inline. **Structural delta** — screens look like Settings/Wallet/Notes. |
| **Wave 3** | 1 per flow (~10 PRs) | Vocabulary + Universal Resource Detail rebuild + screen restructure | Governance → "Decisiones del grupo". ResourceWizard surfaced as concrete actions. MyLedger deeplink renamed. Universal Resource Detail layered scroll canon (Identity / Context / Participation / Coordination / Activity / Actions) per `Fase1ComponentMap.md`. **Conceptual delta** — Ruul stops *feeling* like a configurable framework. |

Each PR ships independently green: build + tests + manual smoke in
simulator iOS 26.

---

## 7. Open questions (do NOT resolve unilaterally — founder pass needed)

1. **14pt vs 16pt text scale**. SF Pro doesn't have a 14pt cut between
   `.callout` (16pt) and `.footnote` (13pt) — choosing for `RuulTypography.callout` (14pt medium) and
   `RuulTypography.subhead` (16pt) requires a per-call-site judgment.
   Default proposal: 14pt → `.footnote`, 16pt → `.subheadline`. Founder
   call: is that OK as a global, or do we want a slot-by-slot review for
   key surfaces (row labels in HomeView, button captions, etc.)?

2. **Spacing token API**. We have BOTH `RuulSpacing.s1`-`s12` (numeric)
   AND `RuulSpacing.xs/.sm/.md/.lg/.xl/.xxl` (semantic) — currently both
   are used. Should we consolidate to one API in Wave 1, or leave both?
   Default proposal: keep both for now (zero blast-radius), deprecate
   numeric in Wave 3 cleanup.

3. **`RuulButton` API surface**. Five styles today (`primary`,
   `secondary`, `glass`, `destructive`, `plain`); native maps to
   `.borderedProminent` + `.bordered` + role `.destructive` + `.plain` +
   `.glass`. The mapping is clean — but should `RuulButton` exist at
   all, or should we inline `Button { } .buttonStyle(...)` at every
   site? Default proposal: KEEP as wrapper because the `isLoading`
   indicator behavior + accessibility consolidation is worth ~5 lines
   saved per call site.

4. **`AsyncContentView`**. Real utility (4 phases) but introduces a
   layer between feature views and content. Founder call: keep, or
   inline `.task` + `if-let` per view + `ContentUnavailableView`?
   Default proposal: keep — replaces 15-20 line boilerplate per use,
   and the empty/error paths use `ContentUnavailableView` internally so
   we still get the native look.

5. **`RuulCoverCatalog` vs user-uploaded covers**. Curated photo
   catalog (real images) is fine per decision #4 (covers as `Image`
   still allowed). Programmatic palette/gradient covers from a UUID
   hash are out. Question: are covers in the app *exclusively*
   user-uploaded today, or do we have a fallback to a curated photo
   when none is uploaded? Default proposal: keep `RuulCoverCatalog` as
   the fallback-photo catalog; delete `RuulCoverPalette` (the
   hash-to-gradient helper) entirely.

6. **`.sheet` vs `.fullScreenCover` policy**. The 2026-05-15 policy
   (`RuulSheet.swift` comment) was "every modal is fullScreenCover with
   explicit close." Apple's pattern is `.sheet` with detents for
   secondary flows (filters, picker overlays), `.fullScreenCover` for
   takeover (wizard, camera, OTP). Default proposal: reverse the 2026-
   05-15 policy. Most current `.fullScreenCover` calls become `.sheet
   { NavigationStack { Form { ... }.toolbar { cancel + save } } }`.
   Founder call needed because this is a meaningful UX change.

7. **`RuulCloseToolbarButton` consistency**. Going forward, sheet
   dismissal should use Apple's standard cancellation:
   `Button("Cancelar") { dismiss() }` in `.cancellationAction`
   placement, NOT an `xmark` icon. Apple uses text ("Cancelar" /
   "Listo") for sheet cancellation, `xmark` only on photo viewers /
   takeover flows. Default proposal: replace `xmark` icon with
   `"Cancelar"` text in `.cancellationAction` for every Form sheet.

---

## 8. What this plan does NOT cover

- Universal Resource Detail layered scroll restructure (Identity / Context / Participation / Coordination(Money/Schedule/Access/Responsibility/Rules/Usage) / Activity / Actions) — structurally in `Fase1ComponentMap.md` §"Universal Resource Detail — layered architecture". SUPERSEDES the earlier "tab restructure" framing 2026-05-20.
- Copy + vocabulary sweep — Deliverable D.
- New empty-state copy per screen — Deliverable D template + 6+ concrete examples.
- Backend / ontology changes — explicitly out of scope.
- New features — out of scope.

---

## 9. Definition of done (for the full simplification plan)

After Wave 1-3 ship:
- `RuulUI` is ~22 files (down from 88).
- No `Color.custom(...)` references in `RuulUI/Sources` or `RuulFeatures/Sources` (other than truly local one-off cases).
- No `Font.custom("Inter...")` references anywhere in the iOS workspace.
- `grep` for banned vocab in user-facing strings returns 0 hits.
- Every screen in the app passes the founder's test: *"Does this feel like an Apple app for coordinating real life together?"*
