# FASE 1 — Onboarding Screen-by-Screen Walkthrough

**Status**: Read-only audit, written 2026-05-19.
**Surface**: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/` (18 files) + supporting Identity models in `ios/Packages/RuulCore/.../PlatformModels/Identity/` + mount point in `ios/Tandas/Shell/AuthGate.swift`.
**Doctrine source**: `~/Library/.../memory/fase1_native_refactor_doctrine.md`.
**Audit base**: `Plans/Active/Fase1NativeAudit.md`.

This is the **ground-truth state** of onboarding before Wave 3. It documents the current copy, components, navigation, HIG violations, and proposes Apple-native targets — without touching any code.

---

## TL;DR

The flow is **functionally complete** (founder happy path + invited happy path + restore-on-relaunch + Keychain `hasOnboarded` flag) but **visually it's a SaaS marketing funnel**: full-bleed `RuulMeshBackground`/`RuulAmbientBackground` painted screens, 88pt `RuulTypography.wordmark` headers, `Color.ruulAccent` gradient pills, custom `OnboardingScreenTemplate` with a `RuulProgressBar` step indicator at the top, custom `RuulTextField` / `RuulPhoneField` / `RuulOTPInput` instead of native `TextField` inside a `Form`, custom `RuulCard` / `RuulActionableCard` / `RuulChip` containers, custom `.ruulPress` / `.ruulMorph` / `.ruulSnappy` animations.

The Tripsy-style **InviteWelcomeView poster** (cover image + gradient vignette + capsule pill CTA) is the most divergent screen from Apple-native — it looks like a travel-app marketing card, not an Apple system invitation.

Doctrine decision #2 (wordmark **kept** only in onboarding/splash/marketing/login) gives onboarding latitude that the rest of the product loses. The wordmark on `WelcomeView` and `OnboardingPathPickerView` is **doctrinally allowed**. The wordmark inside the bootstrapping splash (`AuthGate.BootstrappingView`) is also allowed.

Doctrine decision #4 (group-color theming radically reduced) flags the **InviteWelcomeView ambient palette tinted from the inviting group's cover** as a violation — backgrounds, ambient gradients, and full-screen color from group identity must go. Cover image can stay as content (the poster card), but the screen background should be `Color(.systemBackground)`.

**~80% of the refactor is mechanical** (swap `RuulTypography.X` for system styles, `Color.ruul*` for semantic system colors, `RuulMeshBackground` for `Color(.systemBackground)`, `RuulTextField` for native `TextField` inside `Form`, `RuulButton` for `Button.buttonStyle(.borderedProminent)`).

**~20% is structural** — three screens (`InviteWelcomeView` poster, `ConfirmationView` celebration, `GroupTourOverlay` glass card) need rethinking from "centered hero card on full-bleed gradient" to "navigation-stack screen with content in the body of the canvas."

---

## 0. Flow topology

```
AuthGate (Tandas/Shell/AuthGate.swift)
  ├─ isBootstrapping            → BootstrappingView (wordmark splash)
  ├─ session == nil             → SignInView (Auth feature, out of scope)
  ├─ hasActiveOnboarding ||
     isFirstTimeAuth            → OnboardingRootView
  └─ default                    → RootShell

OnboardingRootView
  ├─ restore from SwiftData     → FounderFlow | InvitedFlow at saved step
  ├─ pendingInviteCode != nil   → InvitedFlow (skip path picker)
  └─ otherwise                  → OnboardingPathPickerView (Step 0)

OnboardingPathPickerView
  ├─ "Crear un grupo nuevo"     → startFounder() → FounderFlow
  └─ "Unirme con código" →
       inline code entry        → startInvited(code) → InvitedFlow

FounderFlow         (NavigationStack, single in-place stepView)
  welcome → identity → group → preset → (consent?) → invite → confirm

InvitedFlow         (NavigationStack, single in-place stepView)
  welcome → identity → phoneVerify → otp → tour
```

**Auth model**: sign-in-first. By the time `FounderOnboardingCoordinator.start()` runs, the user already has a real Supabase session (Apple ID or phone OTP). The founder flow no longer collects phone or OTP — those steps were stripped, only `_ = otp` survives in the init signature for AppState wiring compat (`FounderOnboardingCoordinator.swift:64`).

**Invited flow still collects phone + OTP** because invited users are presumed to be coming from a deep link / shared code on a device where they haven't signed in yet.

**Persistence**: `OnboardingProgress` (SwiftData) stores `flowType`, `founderStepRaw|invitedStepRaw`, `inviteCode`, encoded `GroupDraft`, `displayName`, `phoneE164`, `createdGroupId`, `pendingInvitesJSON`. Updated on every `transition(to:)`. Cleared by `finishOnboarding()` or AuthGate's `refreshOnboardingState()` when `loggedOut || hasGroup`.

**Completion**: `OnboardingCompletion.mark()` writes a Keychain flag (`com.josejmizrahi.ruul.onboarding/has_onboarded`) survives reinstall. Triggered on `advanceFromInvite()` / `skipInvite()` (founder) and inside `submitOTP()` (invited).

---

## Sub-flow A: Founder onboarding

`FounderOnboardingCoordinator` is `@Observable @MainActor`. The flow is linear; back gestures are **not supported** in the current implementation — `NavigationStack` only renders the current `stepView` per a `switch` in `OnboardingRootView.FounderFlow.stepView`, so swiping back from any screen jumps out of onboarding entirely (toolbar is hidden on Welcome/Confirm; the other screens rely on a top-bar back via `OnboardingScreenTemplate`, but the parent is a single `NavigationStack` with no pushed routes — so the back chevron is **not visible**). Mid-flow forward-only.

### A0. OnboardingPathPickerView — "Step 0" path picker

- **Screen ID**: `path-picker`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Shared/OnboardingPathPickerView.swift`
- **Purpose**: Disambiguate first contact — does the user want to **create** a new group or **join** with an invite code? Auto-skipped when `pendingInviteCode` is present (deep link resolved the choice) or when an `OnboardingProgress` is being restored.

#### Current UI
- **Layout**: `ZStack { Color.ruulBackground.ignoresSafeArea() + VStack(spacing: RuulSpacing.xxl) }` — full-bleed background, three vertical chunks (header / path buttons / safe-area pad).
- **Header**: 88pt `Text("ruul")` wordmark + `displayMedium` title ("Bienvenido" / "Pega tu código") + `body` subtitle.
- **Path buttons**: two custom `Button { … }`-with-shape-overlay cards:
  - Primary: black-filled `Color.ruulTextPrimary` rounded rect, "Crear un grupo nuevo" / "Tú armas el grupo desde cero — 2 minutos.", `plus.circle.fill` icon.
  - Secondary: `Color.ruulSurface` filled, "Unirme con código" / "Alguien me compartió un código de invitación.", `person.badge.plus` icon.
- **Join inline block** (toggles in via `withAnimation(.ruulMorph)` move+opacity): `RuulTextField` placeholder "8 caracteres" + `RuulButton("Continuar", .primary, .large)` + plain "Atrás" callout link.
- **Navigation chrome**: `.toolbar(.hidden, for: .navigationBar)` — no top bar. No way back to anything (this *is* Step 0).

#### HIG violations
- **Typography**: `RuulTypography.wordmark` (88pt custom letter-spaced Inter), `displayMedium`, `body`, `headline`, `caption` are all Inter Variable. Doctrine §1 requires San Francisco everywhere.
- **Color**: `Color.ruulBackground` / `.ruulTextPrimary` / `.ruulTextSecondary` / `.ruulTextInverse` / `.ruulSurface` / `.ruulSeparator` instead of `.primary` / `.secondary` / system materials.
- **Layout**: Hand-tuned `RoundedRectangle(cornerRadius: RuulRadius.large).fill(...).overlay(stroke)` cards. Native equivalent: a `List` of two `NavigationLink` rows in an `.insetGrouped` section.
- **Motion**: `withAnimation(.ruulMorph, value: showJoinInput)` + `.transition(.move(edge: .bottom).combined(with: .opacity))` for the inline-code reveal. Custom spring; doctrine §motion requires native `.default`/`.smooth`.
- **Vocabulary**: clean — "grupo", "código de invitación" are user-language.

#### Native target
- Single `NavigationStack` with this view as the root. Replace the full-bleed `ZStack` with a `VStack` over `Color(.systemBackground)`.
- Keep the **wordmark** at the top (decision #2 permits it in onboarding). Render as `Image("RuulWordmark")` text-as-image OR as `Text("ruul").font(.largeTitle).fontWeight(.semibold)` if no asset.
- Below header, drop into native primitives:
  ```swift
  List {
      Section {
          NavigationLink {
              // pushes founder flow start
          } label: {
              Label {
                  VStack(alignment: .leading) {
                      Text("Crear un grupo nuevo")
                      Text("Empieza de cero — tarda dos minutos.")
                          .font(.subheadline).foregroundStyle(.secondary)
                  }
              } icon: { Image(systemName: "plus.circle.fill") }
          }
          NavigationLink {
              // pushes invite-code entry screen
          } label: {
              Label {
                  VStack(alignment: .leading) {
                      Text("Unirme con un código")
                      Text("Alguien te compartió un código.")
                          .font(.subheadline).foregroundStyle(.secondary)
                  }
              } icon: { Image(systemName: "person.badge.plus") }
          }
      }
  }
  .listStyle(.insetGrouped)
  ```
- Inline code entry → push a second screen with `Form { Section { TextField("Código", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled() } }` and a `.toolbar { ToolbarItem(.confirmationAction) { Button("Continuar") {} } }`.
- **Wordmark**: ✅ kept (decision #2).
- **Brand color**: not applicable here — no group context yet.

---

### A1. WelcomeView — "Bienvenido a ruul"

- **Screen ID**: `founder.welcome`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Founder/Views/WelcomeView.swift`
- **Purpose**: First screen after the user taps "Crear un grupo nuevo" in the path picker. **Marketing splash** — no decision, no input, single CTA "Empezar". Used to advance to `.identity`.

#### Current UI
- `ZStack { Color.ruulBackground + VStack(spacing: xxl) }`.
- Wordmark `Text("ruul").ruulTextStyle(RuulTypography.wordmark)`.
- `displayLarge` title: "Bienvenido a ruul".
- `bodyLarge` subtitle: "Vamos a crear tu grupo en 3 minutos."
- `RuulButton("Empezar", style: .primary, size: .large, fillsWidth: true)` calling `coord.advanceFromWelcome()`.
- `.toolbar(.hidden, for: .navigationBar)`.

#### HIG violations
- **Typography**: wordmark, displayLarge, bodyLarge all Inter.
- **Color**: `Color.ruulBackground`, `Color.ruulTextPrimary`, `Color.ruulTextSecondary`.
- **Component**: `RuulButton` is a custom primitive (audit §3 says replace with `.borderedProminent`).
- **Marketing-pattern smell**: doctrine ban list includes "splash heroes" in the product proper; in the onboarding entry, a welcome splash is acceptable but should still feel like the macOS Setup Assistant ("Welcome to Mac") — calm, centered, one CTA, no gradient, no display fonts beyond `.largeTitle`.
- **Vocabulary**: clean — "tu grupo" works.

#### Native target
- `NavigationStack` root for the founder flow. `VStack` over `Color(.systemBackground)`.
- Wordmark image centered.
- `.largeTitle` "Bienvenido a Ruul" + `.body.secondary` "Vamos a crear tu grupo en dos minutos."
- Bottom CTA: `Button("Empezar") {}.buttonStyle(.borderedProminent).controlSize(.large).tint(.accentColor)`.
- **Wordmark**: ✅ kept.
- **Brand color**: not applicable.
- **Question for Wave 3**: should this screen exist at all? It's a marketing interstitial between path picker and identity. Apple Setup Assistant pattern is fine, but the audit's "Welcome stays visible (it's the moment the user decides to accept)" reasoning from `InvitedOnboardingCoordinator` doesn't apply here — there's no information yet. **Candidate to delete**: tap-through could route path-picker → identity directly. Founder confirmed flow keeps welcome but it can be re-evaluated as a quick-win delete.

---

### A2. FounderIdentityView — "¿Cómo te llamas?"

- **Screen ID**: `founder.identity`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Founder/Views/FounderIdentityView.swift`
- **Purpose**: Collect the **founder's** display name + optional avatar. Both end up in `profiles.display_name` / pending avatar upload (V1: local only, no storage upload). Skip allowed.

#### Current UI
- Wrapped in `OnboardingScreenTemplate(mesh: .cool, progress: ..., stepCount: visibleSteps.count, title: "¿Cómo te llamas?", subtitle: "Así te van a ver tus grupos.", primaryCTA: ("Continuar", isLoading, primaryAction), onSkip: skipIdentity, canContinue: !displayName.isEmpty)`.
- Inside content: `VStack` with
  - **Avatar section**: `PhotosPicker` wrapping `RuulAvatar(name: ..., size: .hero, border: .glass)` (148pt circle) with `camera.fill` SF Symbol overlay in a dark-pill at bottom-right.
  - `RuulTextField("Tu nombre", text: $displayName, label: "Nombre")` with `@FocusState` auto-focus on appear.
  - **Sign-in escape**: "¿Ya tienes cuenta? **Iniciar sesión**" link that signs out the anon session, marks `OnboardingCompletion`, routes back to `SignInView`.
- Toolbar: trailing "Saltar" button (set by `OnboardingScreenTemplate`'s `onSkip`).

#### HIG violations
- **Typography**: everything inside `OnboardingScreenTemplate` uses `displayMedium` / `bodyLarge` (Inter).
- **Color**: `Color.ruulTextPrimary` / `.ruulTextSecondary` / `.ruulAccent` (the sign-in link) / `.ruulTextInverse` (camera icon foreground) / `.ruulSurface` / `.ruulSeparator`.
- **Form pattern**: not a `Form`. The text field is a custom `RuulTextField` (floating label + glass border + custom focus animation). Apple's identity step in Setup Assistant uses a plain `Form { Section { TextField } }`.
- **Avatar treatment**: 148pt avatar with `.glass` border is **out of scale** for an identity field. Apple Photos for Family / iCloud setup uses a small circular avatar (~80pt) inline with the name field, not a centerpiece.
- **Custom progress bar**: `RuulProgressBar(value: progress, style: .steps(stepCount))` at the top of the screen. Apple Setup Assistant rarely shows a progress bar; Calendar / Reminders setup uses a step indicator only when there are many discrete steps. 5 visible steps is borderline — could be dropped.
- **Vocabulary**: "Así te van a ver tus grupos" — clean.

#### Native target
```swift
NavigationStack {
    Form {
        Section {
            HStack {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    Circle().fill(.tertiary).frame(width: 60, height: 60).overlay {
                        // initials or selected image
                    }
                }
                TextField("Nombre", text: $displayName)
            }
        } footer: {
            Text("Así te van a ver tus grupos.")
        }

        Section {
            Button("¿Ya tienes cuenta? Iniciar sesión") { switchToSignIn() }
        }
    }
    .navigationTitle("¿Cómo te llamas?")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Saltar") { Task { await coord.skipIdentity() } }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Continuar") { Task { await coord.advanceFromIdentity() } }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
```
- **Wordmark**: ❌ removed (only Step 0 + Welcome keep it).
- **Brand color**: only the avatar (initials background) may use a small group/personal color accent — not applicable here since the user is not yet in a group.

---

### A3. GroupIdentityView — "Crea tu grupo"

- **Screen ID**: `founder.group`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Founder/Views/GroupIdentityView.swift`
- **Purpose**: Collect the **group's** name. The group is materialized in Supabase at the *next* step (preset selection calls `groupRepo.createInitial`), so this screen just stages the `draft.name`.

#### Current UI
- Wrapped in `OnboardingScreenTemplate` (mesh: .cool, title: "Crea tu grupo", subtitle: "Tu grupo se vuelve vivo en cuanto le pongas nombre.", primaryCTA: "Crear grupo", canContinue: `draft.isReadyToCreate`).
- Content:
  - `RuulTextField("Nombre del grupo", text: $draft.name, label: "Nombre")` auto-focused.
  - **Suggestion chips row**: horizontal `ScrollView` with `RuulChip` instances for ["Los Cuates", "El Grupo", "Domingo Familiar", "La Banda"]. Custom chip style.
  - Inline error: red `.ruulNegative` `caption` text below the field if `coord.error == .createGroupFailed`.
- **Dead code marker**: lines 37-43 comment notes the cover picker was removed; `draft.coverImageName` stays `nil`. No DEAD_CODE in this file.

#### HIG violations
- **Typography**: same Inter family throughout.
- **Color**: `.ruulTextPrimary` / `.ruulTextSecondary` / `.ruulNegative` (error). Replace with `.primary` / `.secondary` / `.red`.
- **Suggestion chips**: `RuulChip(style: .suggestion)` is a custom primitive. Audit §3.A flags it for replacement.
- **CTA semantics**: button labelled "Crear grupo" but the actual group creation happens at the **next** step (preset selection). Copy is misleading. Should be "Continuar".
- **Vocabulary**: "Tu grupo se vuelve vivo en cuanto le pongas nombre" — *just slightly* over-promising/marketing. Apple-native equivalent: "Ponle nombre" or just no subtitle.

#### Native target
```swift
Form {
    Section {
        TextField("Nombre del grupo", text: $draft.name)
            .focused($nameFocused)
    } footer: {
        Text("Puedes cambiarlo después.")
    }

    Section("Sugerencias") {
        ForEach(suggestions, id: \.self) { name in
            Button(name) { draft.name = name }
                .foregroundStyle(.primary)
        }
    }
}
.navigationTitle("Tu grupo")
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button("Continuar") { Task { await coord.advanceFromGroupIdentity() } }
            .disabled(!coord.draft.isReadyToCreate)
    }
}
```
Or: keep the chips as a horizontal row, but render them with native `Capsule().background(.tint.opacity(0.15))` styling rather than `RuulChip`.

**Copy proposal**: drop subtitle entirely OR `Text("Puedes cambiarlo después.").font(.subheadline).foregroundStyle(.secondary)` as a Section footer.

- **Wordmark**: ❌ removed.
- **Brand color**: not applicable — the group has no color identity yet (cover picker was deleted).

---

### A4. PresetPickerView — "¿Para qué será tu grupo?"

- **Screen ID**: `founder.preset`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Founder/Views/PresetPickerView.swift`
- **Purpose**: Pick a starter template ("Reuniones recurrentes" / "Activo compartido" / "Empezar de cero"). On `coord.selectPreset(_:)` the group is **materialized in Supabase** (`groupRepo.createInitial`) and template rules are seeded server-side. Routes to `.consent` if rules seeded, else jumps to `.invite`. Beta gate (`BetaFeatureFlags.showAllPresets == false`) **hides** the two non-recurring-dinner cards in Beta 1 builds.

#### Current UI
- Wrapped in `OnboardingScreenTemplate` (mesh: .cool, dynamic title `"¿Para qué será \(draft.name)?"`, subtitle: "Elige cómo arrancar. Puedes agregar más después.").
- Primary CTA `("Continuar", isLoading, selectPreset(_:))` **only appears after a card is tapped** (the `continueCTA` computed prop returns nil when no preset selected).
- Content: `VStack(spacing: RuulSpacing.md)` of 1-3 preset cards (Beta filters down to 1).
- Each `presetCard`:
  - `HStack(top, spacing: md)`.
  - **Icon zone**: 48×48 `Circle` filled with `Color.ruulAccent.opacity(0.15)` (selected) or `Color.ruulSurface` (default), containing an SF Symbol from `preset.icon`.
  - **Text zone**: `headline` displayName, `caption` summary, then a bullet list of `sampleResources` rendered as `circle.fill` micro-dots + `caption` lines.
  - **Checkmark**: `checkmark.circle.fill` in `Color.ruulAccent` (right side) when selected, with `.scale.combined(with: .opacity)` transition.
  - **Container**: `RoundedRectangle(cornerRadius: RuulRadius.large).fill(.ultraThinMaterial)` + `.stroke(isSelected ? .ruulAccent : .ruulSeparator, lineWidth: isSelected ? 2 : 1)`. **Note**: this is the only spot in onboarding using `.ultraThinMaterial` natively — but it's a card, not a floating toolbar, so it violates doctrine #5 (glass kept but controlled — never on cards).

#### HIG violations
- **Glass on cards**: `.ultraThinMaterial` on every preset card. Doctrine #5: never on every card. Should be plain `Color(.secondarySystemGroupedBackground)`.
- **Selection chrome**: 2pt stroke ring around the selected card + checkmark to the right. Apple pattern for selection in lists: a checkmark on the right and inset highlight via `.listRowBackground`. The double affordance (ring + checkmark) is redundant.
- **Custom animation**: `withAnimation(.ruulSnappy)` on selection. Replace with `.default` or implicit.
- **Typography**: every line is Inter (`headline`, `caption`, etc. via `ruulTextStyle`).
- **Sample resource bullets**: "Cena semanal", "Multas por no-show", "Host rotativo" rendered with `circle.fill` dots. Native-er: render as a comma-joined `.caption2` line OR a `Label` per bullet.
- **Vocabulary**: clean — "Reuniones recurrentes", "Activo compartido", "Empezar de cero" are user-language.
- **Title interpolation edge case**: when `draft.name` is empty (e.g. user came from restore without name), falls back to "tu grupo". Works.
- **Subtitle**: "Elige cómo arrancar. Puedes agregar más después." — acceptable, slightly marketing tone.

#### Native target
```swift
Form {
    Section {
        ForEach(visiblePresets) { preset in
            Button {
                selected = preset
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.displayName).foregroundStyle(.primary)
                        Text(preset.summary)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: preset.icon).foregroundStyle(.tint)
                }
            }
            .listRowBackground(
                selected?.id == preset.id ? Color.accentColor.opacity(0.1) : nil
            )
            .overlay(alignment: .trailing) {
                if selected?.id == preset.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    } header: {
        Text("¿Para qué será \(coord.draft.name)?")
    } footer: {
        Text("Puedes agregar más después.")
    }
}
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button("Continuar") { Task { await coord.selectPreset(selected!) } }
            .disabled(selected == nil)
    }
}
```
- Bullets / sample resources: native-equivalent would be a Section footer per card or fold them into the summary. They add noise — consider dropping in Wave 3.
- Loading state: when `coord.isLoading` (group being materialized), disable the section and show a `ProgressView()` in the toolbar.
- **Wordmark**: ❌ removed.
- **Brand color**: not applicable.

---

### A5. ConsentRulesView — "Reglas sugeridas" (conditional)

- **Screen ID**: `founder.consent`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Founder/Views/ConsentRulesView.swift`
- **Purpose**: Surface the rules just seeded by `selectPreset(_:)` (server-side `seedTemplateRules` RPC). Read-only — rules are seeded with `isActive=false` ("modo sugerencia"). Pure forward — `advanceFromConsent` just routes to `.invite`. **Skipped** when the preset has no `templateId` ("Empezar de cero").

#### Current UI
- `OnboardingScreenTemplate(mesh: .cool, title: "Reglas sugeridas", subtitle: "Estas son las reglas que la gente suele usar. Por ahora están en modo sugerencia — no se activan hasta que tu grupo decida.", primaryCTA: ("Continuar", false, advanceFromConsent), canContinue: true)`.
- Content: `VStack(alignment: .leading, spacing: sm)`:
  - `ForEach(coord.templateRulePreviews)` rows. Each row: `HStack` with `RuulIconBadge("doc.text", size: .medium)` + 2-line text (rule `name` in `headline` + "En modo sugerencia" in `caption`), inside a `Color.ruulSurface` rounded-rect `card` with `.ruulSeparator` 0.5pt stroke.
  - Footnote: `info.circle` + caption "Podrás revisar y activar cada regla desde la sección Reglas cuando estén todos listos."

#### HIG violations
- **Card pattern again**: every rule is a stacked rounded-rect with custom shadow/stroke. Doctrine: replace with `List { Section { ForEach } }`.
- **`RuulIconBadge`** is custom — a 40×40 colored circle with an SF Symbol. Native: just `Image(systemName: ...).foregroundStyle(.tint)` inside a `Label`.
- **Typography**: Inter everywhere.
- **Vocabulary OK**: "Reglas sugeridas", "en modo sugerencia", "la sección Reglas" — clean. **NB**: "regla" in user-facing copy is fine (doctrine bans "rule shape" / "consequence" / "trigger", not "regla").
- **Long subtitle**: 110-char subtitle wraps to 3 lines. Apple style is shorter — break into a one-line subtitle + a Section footer for the disclaimer.

#### Native target
```swift
Form {
    Section {
        ForEach(coord.templateRulePreviews) { rule in
            Label {
                VStack(alignment: .leading) {
                    Text(rule.name)
                    Text("En modo sugerencia")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "doc.text").foregroundStyle(.tint) }
        }
    } header: {
        Text("Reglas sugeridas")
    } footer: {
        Text("Las reglas no se activan hasta que tu grupo decida. Puedes revisarlas en la sección Reglas.")
    }
}
.navigationTitle("Reglas sugeridas")
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button("Continuar") { Task { await coord.advanceFromConsent() } }
    }
}
```
- **Wordmark**: ❌ removed.
- **Brand color**: not applicable.
- **Copy proposals**:
  - Title kept: "Reglas sugeridas"
  - Footer (replaces subtitle): "Las reglas no se activan hasta que tu grupo decida. Puedes revisarlas y activarlas más adelante."

---

### A6. InviteMembersView — "Invita a tu grupo"

- **Screen ID**: `founder.invite`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Founder/Views/InviteMembersView.swift`
- **Purpose**: Collect a list of `PendingInvite` (phoneE164 + optional displayName) **before** sending. The actual `inviteRepo.createInvite` calls run when the user taps "Continuar" (`advanceFromInvite`). Skip allowed.

#### Current UI
- `OnboardingScreenTemplate(mesh: .cool, title: "Invita a tu grupo", subtitle: "Mínimo 3 personas para empezar.", primaryCTA: ("Continuar", isLoading, advanceFromInvite), secondaryCTA: ("Saltar", skipInvite), canContinue: true)`.
- Content:
  - **Share link card**: `ShareLink(item: InviteLinkGenerator.shareMessage(...))` labeled as `HStack` with `RuulIconBadge("link")` + headline "Compartir link" + caption "Mándalo por WhatsApp, SMS, donde sea." + trailing `square.and.arrow.up`. Rounded `Color.ruulSurface` card.
  - **Import contacts card**: `RuulActionableCard(icon: "person.crop.circle.badge.plus", title: "Importar de contactos", subtitle: "...", accessory: .badge("Recomendado"))` opens a native `CNContactPickerViewController` via `UIViewControllerRepresentable`.
  - **Manual entry button**: plain caption-sized button "Escribirlo a mano" with `keyboard` icon → opens `ruulSheet` containing a `ModalSheetTemplate` with `RuulTextField("Nombre")` + `RuulPhoneField`.
  - **Pending list**: when `pendingInvites.count > 0`, renders "Por invitar (\(count))" header + a custom `VStack` of `HStack` rows with name/phone + remove `xmark.circle.fill` button OR `checkmark.circle.fill` in green for already-sent invites (post-`advanceFromInvite` re-render).
- **Subtitle copy issue**: "Mínimo 3 personas para empezar" is **misleading** — the screen has a "Saltar" CTA and `advanceFromInvite` does not enforce a minimum.

#### HIG violations
- **Three card primitives**: Share link card (hand-built), `RuulActionableCard` (custom primitive), and the manual-entry chip-link. Native pattern would be a single `List` with:
  - Section 1: "Compartir link" row (`ShareLink` natively works inside `List` rows).
  - Section 2: "Importar de contactos" `NavigationLink` (or `Button` opening sheet) + "Escribir manualmente" `Button` opening sheet.
  - Section 3: "Por invitar" — list of `PendingInvite` rows with native `.swipeActions { Button(role: .destructive) {} label: { Label("Quitar", systemImage: "trash") } }` instead of inline `xmark.circle.fill`.
- **`RuulActionableCard` + badge "Recomendado"**: violates doctrine — the "Recomendado" badge is a marketing affordance. Apple doesn't badge rows in Settings. Drop it.
- **Manual entry sheet** uses `ModalSheetTemplate` (deletable per audit §3.D). Replace with native `.sheet { NavigationStack { Form { ... } .toolbar { ToolbarItem(.confirmationAction) { Button("Agregar") {} } } } }`.
- **`ruulSheet`** modifier wraps the native sheet — delete.
- **`RuulPhoneField`** is a domain primitive — audit §3.B says keep (phone formatting is non-trivial), but it currently renders custom chrome; rebuild internals to use a plain `TextField` with `.keyboardType(.phonePad)` and a manual format-on-edit closure.
- **Subtitle copy**: "Mínimo 3 personas para empezar" — does not match behavior (Skip works without 3). Fix copy or enforce.
- **Pending list dividers**: hand-built `Divider()` between rows. Native `List` provides separators automatically.
- **Vocabulary**: clean — "Compartir link", "Importar de contactos", "Por invitar".

#### Native target
```swift
Form {
    Section {
        ShareLink(item: InviteLinkGenerator.shareMessage(...)) {
            Label("Compartir link", systemImage: "square.and.arrow.up")
        }
        Button { contactsPresented = true } label: {
            Label("Importar de contactos", systemImage: "person.crop.circle.badge.plus")
        }
        Button { manualEntryPresented = true } label: {
            Label("Escribir manualmente", systemImage: "keyboard")
        }
    }

    if !coord.pendingInvites.isEmpty {
        Section("Por invitar (\(coord.pendingInvites.count))") {
            ForEach(coord.pendingInvites) { invite in
                HStack {
                    VStack(alignment: .leading) {
                        if let name = invite.displayName { Text(name) }
                        Text(PhoneFormatter.displayFormat(invite.phoneE164))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if invite.sentAt != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .swipeActions(allowsFullSwipe: true) {
                    Button(role: .destructive) { remove(invite) } label: {
                        Label("Quitar", systemImage: "trash")
                    }
                }
            }
        }
    }
}
.navigationTitle("Invitar al grupo")
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button("Continuar") { Task { await coord.advanceFromInvite() } }
    }
    ToolbarItem(placement: .bottomBar) {
        Button("Saltar por ahora") { Task { await coord.skipInvite() } }
    }
}
.sheet(isPresented: $contactsPresented) { ContactPicker(onPicked: ...) }
.sheet(isPresented: $manualEntryPresented) {
    NavigationStack {
        Form {
            Section {
                TextField("Nombre (opcional)", text: $manualName)
                TextField("Teléfono", text: $manualPhone)
                    .keyboardType(.phonePad)
            }
        }
        .navigationTitle("Agregar miembro")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") {} }
            ToolbarItem(placement: .confirmationAction) { Button("Agregar") {} }
        }
    }
}
```
- **Copy proposals**:
  - Title: "Invitar al grupo"
  - Subtitle removed (or move to Section footer: "Comparte el link, importa contactos, o agrega manualmente.")
- **Wordmark**: ❌ removed.
- **Brand color**: not applicable.

---

### A7. ConfirmationView — "Tu grupo está vivo"

- **Screen ID**: `founder.confirm`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Founder/Views/ConfirmationView.swift`
- **Purpose**: Celebration / landing. Three CTAs: "Crear el primer evento" (→ `.createFirstEvent`), "Invitar más gente" (→ `.inviteMore`), "Ir al inicio" (→ `.home`). On `.task`: trigger `.success` sensory feedback + call `coord.finishOnboarding()` (clears the SwiftData entity).

#### Current UI
- `ZStack { RuulMeshBackground(.violet) + VStack(spacing: xxl) }`. **Violet** mesh background full-bleed.
- Hero block: `displayLarge` "Tu grupo está vivo" + `bodyLarge` "\(group.name) tiene \(pendingInvites.count) miembros invitados."
- CTA stack:
  - `RuulButton("Crear el primer evento", .primary, .large, fillsWidth)`.
  - `RuulButton("Invitar más gente", .glass, .large, fillsWidth)`.
  - `RuulButton("Ir al inicio", .plain, .medium)`.
- `.toolbar(.hidden)`.
- `.sensoryFeedback(.success, trigger: feedback)`.

#### HIG violations
- **Full-bleed colored mesh background**: doctrine #4 prohibits ambient backgrounds. Major violation.
- **Display-size hero text**: `displayLarge` is bigger than Apple's `.largeTitle`.
- **"Tu grupo está vivo"**: marketing copy. Apple-native equivalent would be more functional ("Listo." or "Grupo creado.")
- **Three stacked CTAs of decreasing visual weight**: the pattern is acceptable (Apple Watch onboarding does this), but `RuulButton(.glass)` violates doctrine #5 (glass on dashboard-y buttons). Use `.bordered` for the middle and `.borderless` (or plain `Button`) for the third.
- **Stat-y subtitle**: "\(group.name) tiene \(pendingInvites.count) miembros invitados" — fine, but note `pendingInvites.count` is the *count after `advanceFromInvite`* which includes both sent and unsent. Slightly inaccurate if any invites failed. (Bug, not HIG, but flag.)

#### Native target
- This screen is **canonical celebration territory** for Apple. The closest analog is the "All set" screen in iCloud setup or Apple Pay confirmation. Pattern:
  ```swift
  VStack(spacing: 24) {
      Image(systemName: "checkmark.circle.fill")
          .resizable().frame(width: 80, height: 80)
          .foregroundStyle(.green)
          .symbolEffect(.bounce)
      VStack(spacing: 8) {
          Text("Listo").font(.largeTitle).bold()
          Text("\(group.name) está creado.")
              .font(.body).foregroundStyle(.secondary)
      }
      Spacer()
      VStack(spacing: 12) {
          Button("Crear el primer evento") { onCreateFirstEvent() }
              .buttonStyle(.borderedProminent)
              .controlSize(.large).frame(maxWidth: .infinity)
          Button("Invitar a más gente") { onInviteMore() }
              .buttonStyle(.bordered)
              .controlSize(.large).frame(maxWidth: .infinity)
          Button("Ir al inicio") { onGoHome() }
              .controlSize(.regular)
      }
  }
  .padding()
  .background(Color(.systemGroupedBackground))
  .sensoryFeedback(.success, trigger: feedback)
  ```
- **Wordmark**: ❌ removed.
- **Brand color**: not applicable.
- **Copy proposals**:
  - Title: "Listo" (or "Grupo creado")
  - Subtitle: "\(group.name) está listo." (drop the invite count — it's noise on a celebration screen).

---

## Sub-flow B: Invited onboarding

`InvitedOnboardingCoordinator` is `@Observable @MainActor`. Steps: welcome → identity → phoneVerify → otp → tour.

### B1. InviteWelcomeView — "Te invitan a unirte a [Group]"

- **Screen ID**: `invited.welcome`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Invited/Views/InviteWelcomeView.swift`
- **Purpose**: First contact for an invited user. Shows `InvitePreview` (group name, cover image, member count, recent member names, group creation date). Two CTAs: "Aceptar invitación" → `coord.acceptInvitation` → identity step. "Ahora no" → `onDecline()` → dismiss (back to nothing, no clear UX recovery).

#### Current UI — Tripsy-style poster
- `ZStack { ambientBackground + content }`.
- **`ambientBackground`**: if preview loaded, `RuulAmbientBackground(palette: cover.palette, style: .vivid)` — **full-bleed colored gradient derived from the inviting group's cover image palette**. Otherwise fallback `RuulMeshBackground(.aqua)`.
- **`content`** → `AsyncContentView(phase: coord.previewPhase, loaded: previewLayout)`:
  - **Avatar stack** (top): `RuulAvatarStack(people: preview.recentMemberNames.prefix(5), size: .large, maxVisible: 5)`.
  - **Headline**: small `bodyLarge` "Te invitan a unirte a" in `.ruulOnImageSecondary` (semi-transparent white) + `displayLarge` `preview.groupName` in `.ruulOnImage` (white) with a shadow.
  - **Poster card** (hero):
    - `ZStack(alignment: .bottomLeading) { RuulCoverView(cover) + LinearGradient(deepBottom) + meta-text-block }`
    - Aspect ratio 0.78 (vertical poster).
    - `.clipShape(RoundedRectangle(cornerRadius: RuulRadius.hero))` + `.ruulElevation(.lg)` (heavy shadow).
    - Inside the meta-block: `title` group name + `callout` meta (recent names + "y N más" or "N miembros") + `caption` "Activo desde mayo 2026".
  - **Action stack**:
    - Primary: custom `Button` rendering "Aceptar invitación" in `bodyLarge` on a `Capsule().fill(Color.ruulImagePillSolid)` (translucent/glass pill) with `.ruulElevation(.sm)`.
    - Secondary: plain "Ahora no" `body` text in `Color.ruulTextSecondary`.
- `.toolbar(.hidden, for: .navigationBar)`.

#### HIG violations — **highest in the entire flow**
- **Full-bleed ambient background tinted from group cover**: doctrine #4 explicit ban ("DELETE: tinted screens, per-group backgrounds, gradients, ambient color dominance"). This is **the** canonical violation.
- **Wordmark-class display title** (`displayLarge` for group name) — bigger than Apple's `.largeTitle`.
- **Travel-poster card** with 0.78 aspect ratio + vignette gradient + meta text overlay: pure SaaS / consumer-marketing aesthetic. Apple uses **identity tiles** (Wallet pass) or **plain list rows** for invitations (Find My, Calendar invites). The pattern most analogous in Apple's own apps is **Calendar invitation** (a tile-shaped row with title + date + sender + Accept/Decline buttons) or **Wallet card preview**.
- **Custom shadow elevations**: `.ruulElevation(.lg)`, `.ruulElevation(.sm)`. Doctrine: delete most shadow tokens.
- **Custom capsule CTA**: `Capsule().fill(.ruulImagePillSolid).ruulElevation(.sm)` — non-Apple button style. Use `.buttonStyle(.borderedProminent)` or `.borderedProminent` on a capsule shape via native API.
- **Three different white tones for foreground over image** (`.ruulOnImage`, `.ruulOnImageSecondary`, `.ruulOnImageInverse`, `.ruulImageTextShadow`) — replace with semantic `.primary` over `.thinMaterial`.
- **Vocabulary**: clean. "Te invitan a unirte a", "Aceptar invitación", "Ahora no" are user-language.
- **"Ahora no" UX dead-end**: `onDecline` callback is wired to dismiss the overlay, but the caller (`OnboardingRootView.InvitedFlow`) passes `{ onCompleted() }` — meaning "Ahora no" **completes onboarding** and routes to home. That feels wrong: a decline should likely return to a sign-in or path-picker state. Edge case.

#### Native target — Apple Calendar/Find My invitation pattern
```swift
NavigationStack {
    ScrollView {
        VStack(spacing: 24) {
            // Cover image as content, not background. Inset, not full-bleed.
            Image("group-cover-...")
                .resizable().scaledToFill()
                .frame(height: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

            VStack(spacing: 8) {
                Text("Te invitaron a")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(preview.groupName)
                    .font(.largeTitle).bold()
                    .multilineTextAlignment(.center)
            }

            // Social proof: avatars + caption
            VStack(spacing: 12) {
                AvatarStack(names: preview.recentMemberNames)  // domain wrapper
                Text(memberSummary(preview))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
    .toolbar {
        ToolbarItem(placement: .bottomBar) {
            VStack(spacing: 8) {
                Button("Unirme al grupo") { Task { await coord.acceptInvitation() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("Ahora no") { onDecline() }
                    .controlSize(.regular)
            }
        }
    }
    .background(Color(.systemBackground))
}
```
- **Wordmark**: ❌ removed (decision #2 lists "welcome/login" — InviteWelcome is more like a Calendar invitation than a brand splash).
- **Brand color**: cover image stays as **content** (inset image), not as **structure** (background). Avatars in the stack can use per-person color, that's fine.
- **Copy proposals**:
  - Header: "Te invitaron a" (drop "unirse a", more direct)
  - Group name as `.largeTitle.bold`
  - Meta: "Miguel, Ana y Jose · Activo desde mayo 2026" — one line, `.caption`/`.subheadline`, secondary color.
  - Primary CTA: "Unirme al grupo"
  - Secondary: "Ahora no"
- **"Ahora no" routing**: review — should likely pop the InvitedFlow and route back to `OnboardingPathPickerView` rather than completing onboarding.

---

### B2. InvitedIdentityView — "¿Cómo te llamas?"

- **Screen ID**: `invited.identity`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Invited/Views/InvitedIdentityView.swift`
- **Purpose**: Collect the **invited user's** display name + avatar. Mirror of `FounderIdentityView` minus the sign-in escape link.

#### Current UI
- `OnboardingScreenTemplate(mesh: .aqua, ...)` — same template as founder.
- Same `PhotosPicker` + 148pt `RuulAvatar(.hero)` + `camera.fill` overlay.
- Same `RuulTextField` auto-focused.
- Subtitle: "El grupo necesita saber quién entra."

#### HIG violations
- **All the same violations as A2** (FounderIdentityView): Inter, custom colors, custom progress bar, avatar at hero size, custom text field.
- **Subtitle copy**: "El grupo necesita saber quién entra" — anthropomorphizes the group, slightly off. Apple-native: "Así te van a ver tus amigos en el grupo." or even just no subtitle.

#### Native target
Same as A2. `Form { Section { HStack { PhotosPicker { Circle().frame(60) } TextField("Nombre", text: $displayName) } } }` + `navigationTitle("¿Cómo te llamas?")` + bottom-bar "Continuar" button.

- **Wordmark**: ❌ removed.
- **Brand color**: avatar only, after the user enters a name — `RuulAvatar` already picks a color from initials → fine to keep.

---

### B3. InvitedVerifyView — "Confirma tu número"

- **Screen ID**: `invited.phoneVerify`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Invited/Views/InvitedVerifyView.swift`
- **Purpose**: Collect phone in E.164 format. On "Enviar código" → `coord.advanceFromPhoneVerify()` calls `otp.requestCode(phoneE164:)` and routes to OTP step.

#### Current UI
- `OnboardingScreenTemplate(mesh: .aqua, title: "Confirma tu número", subtitle: "Para mandarte recordatorios y multas si aplica.", primaryCTA: ("Enviar código", isLoading, sendCode), canContinue: !empty)`.
- Content:
  - `RuulPhoneField(text: $phoneInput, label: "Tu número", error: errorMessage)`.
  - Caption: "Te llamamos primero por WhatsApp. Si no llega, te mandamos un SMS."

#### HIG violations
- **"...y multas si aplica"**: bans-list-adjacent — "multas" is fine (rule consequences are user-language) but the parenthetical makes the screen feel like a **terms-of-service surface**, not a phone-verify. Apple Sign In / Phone Auth doesn't disclose downstream features in the verify step. Move that to a footer or drop entirely.
- **`RuulPhoneField`**: keep as domain wrapper, but rebuild on `TextField` + `.keyboardType(.phonePad)` + `.textContentType(.telephoneNumber)`.
- **Subtitle is OK** as an honest disclosure of OTP behavior but should be **the caption**, not the screen subtitle.
- **Typography / color**: as before.
- **Vocabulary**: clean — "Confirma tu número", "Enviar código", "WhatsApp", "SMS".

#### Native target
```swift
Form {
    Section {
        TextField("+52 55 1234 5678", text: $phoneInput)
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
    } header: {
        Text("Tu número")
    } footer: {
        Text("Te llamamos primero por WhatsApp. Si no llega, te mandamos un SMS.")
    }
}
.navigationTitle("Confirma tu número")
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button("Enviar código") { sendCode() }
            .disabled(phoneInput.isEmpty)
    }
}
```
- **Wordmark**: ❌ removed.
- **Brand color**: not applicable.
- **Copy proposals**:
  - Subtitle removed; carry the WhatsApp/SMS line to the Section footer.
  - Drop "y multas si aplica" — it's a future-feature-disclosure that doesn't help the user complete this step.

---

### B4. InvitedOTPView — "Te mandamos un código"

- **Screen ID**: `invited.otp`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Invited/Views/InvitedOTPView.swift`
- **Purpose**: Collect 6-digit OTP. Calls `coord.submitOTP(code:)`. On success → tour step. On failure: increment attempts, show error, allow resend after 30s.

#### Current UI
- `OnboardingScreenTemplate(mesh: .aqua, title: titleForChannel, subtitle: "Llega a \(formattedPhone). Pégalo aquí.", primaryCTA: ("Confirmar", isLoading, submit), canContinue: code.count == 6)`.
- `titleForChannel`: "Te mandamos un código por WhatsApp" or "Te mandamos un SMS" based on `otpChannel`.
- Content:
  - `RuulOTPInput(code: $code, hasError: $hasError, onComplete: submit)` — 6 separate digit cells. Domain primitive, keeping per audit §3.B.
  - **Resend button**: "Reenviar (\(N)s)" greyed out for 30s, then "Reenviar código" in accent.
  - Inline error messages:
    - "Código incorrecto. Te quedan \(N) intentos." for `otpVerifyFailed` with attempts < 3.
    - "Demasiados intentos. Pide otro código." for `otpTooManyAttempts`.

#### HIG violations
- **Title shifts**: "Te mandamos un código por WhatsApp" vs "Te mandamos un SMS" — two different titles based on a runtime branch. Apple-native equivalent uses a stable title ("Código de verificación") and shifts the **subtitle** to reflect channel.
- **Error inline text in `Color.ruulNegative` `caption`**: native would be Section footer `.foregroundStyle(.red)`. Or, more Apple-y, a `.controlSize(.regular).foregroundStyle(.red)` text below the field.
- **Resend button** as plain `Button` with a manual countdown — works, but Apple Phone Auth uses a `Button("Reenviar código").disabled(resendCountdown > 0)` with the countdown in the **label** (which the current code does — that part is fine).
- **`RuulOTPInput`** stays as a domain primitive but should be audited for `.textContentType(.oneTimeCode)` and SMS autofill compliance (per audit §3.B).
- **Typography / color**: as before.
- **Vocabulary**: clean.

#### Native target
```swift
Form {
    Section {
        OTPField(code: $code)  // domain wrapper, .textContentType(.oneTimeCode)
            .focused($otpFocused)
    } header: {
        Text("Código de verificación")
    } footer: {
        Text("Llega a \(PhoneFormatter.displayFormat(coord.phoneE164)) por \(coord.otpChannel == .whatsapp ? "WhatsApp" : "SMS").")
    }

    if let err = coord.error,
       case .otpVerifyFailed(_, let attempts) = err, attempts < 3 {
        Section {
            Text("Código incorrecto. Te quedan \(3 - attempts) intentos.")
                .foregroundStyle(.red)
        }
    }

    Section {
        Button("Reenviar código") { resend() }
            .disabled(resendCountdown > 0)
            .foregroundStyle(resendCountdown > 0 ? .secondary : .tint)
        if resendCountdown > 0 {
            // or just inline the countdown in the button label
            Text("Disponible en \(resendCountdown)s").font(.caption).foregroundStyle(.secondary)
        }
    }
}
.navigationTitle("Código de verificación")
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button("Confirmar") { submit() }.disabled(code.count != 6)
    }
}
```
- **Wordmark**: ❌ removed.
- **Brand color**: not applicable.
- **Copy proposals**:
  - Title: "Código de verificación" (stable across channels).
  - Footer mentions channel + phone.

---

### B5. GroupTourOverlay — welcome card

- **Screen ID**: `invited.tour`
- **File**: `Packages/RuulFeatures/Sources/RuulFeatures/Features/Onboarding/Invited/Views/GroupTourOverlay.swift`
- **Purpose**: Modal welcome card after OTP succeeds. 3-bullet introduction: "Cuando haya un próximo evento te aviso", "Las reglas viven aquí", "Tienes período de gracia: las primeras 3 reuniones no aplican multas." On "Entendido" → wallet pass generation (stub, V1 no-op) → dismiss → `onCompleted()`.

#### Current UI
- `ZStack { Color.ruulOverlayDim + RuulCard(.tile)-content }`.
- Animated `visible` state: dim + scale-in `card` via `.ruulMorph` + `.ruulSmooth`.
- `RuulCard(.tile)` contains:
  - `titleLarge` "Bienvenido a \(group.name)".
  - `body` subtitle "Esto es lo que necesitas saber:".
  - **3 bullets**:
    - `calendar` icon + "Cuando haya un próximo evento, te aviso aquí." (generic V1 fallback per comment).
    - `list.bullet.clipboard` icon + "Las reglas del grupo viven aquí. Léelas cuando puedas."
    - `shield.checkered` icon + "Tienes período de gracia: las primeras 3 reuniones no aplican multas."
  - `RuulButton("Entendido", .primary, .large, fillsWidth)`.
- `.ruulElevation(.lg)` on the card.
- Renders **on top of nothing useful** — `InvitedFlow.stepView` wraps it in `ZStack { Color.ruulBackground.ignoresSafeArea() + GroupTourOverlay }`. So the "overlay" actually has just `ruulBackground` behind it, not the actual group home.

#### HIG violations
- **`RuulCard(.tile)` + `ruulElevation(.lg)`**: doctrine #5 (glass on cards) and audit §3.A (`RuulCard` delete).
- **"Overlay" pattern that isn't really an overlay** — there's no group home view rendered behind it (just `ruulBackground`). It looks like a modal card floating in empty space. Apple-native: this should be a **sheet** (`.sheet { ... .presentationDetents([.medium]) }`) or a full screen wrapped in `NavigationStack`.
- **`shield.checkered`** is an unusual SF Symbol choice — `clock.badge.checkmark` or `gift` would feel more natural for "grace period".
- **"Las primeras 3 reuniones no aplican multas"**: hard-coded V1 marketing copy — accurate to current behavior (grace period is real) but should be derived from group state, not hardcoded.
- **`titleLarge`**: Inter, custom size.
- **Vocabulary**: clean — "evento", "reglas del grupo", "multas", "reuniones".
- **Generic "Cuando haya un próximo evento" copy**: comment notes V1 doesn't thread event data through. The bullet is filler.

#### Native target — two options
**Option A: Sheet with `.presentationDetents([.medium])`**
```swift
.sheet(isPresented: $tourPresented) {
    NavigationStack {
        Form {
            Section {
                Label("Te avisamos cuando haya un próximo evento.",
                      systemImage: "calendar")
                Label("Las reglas del grupo viven en la sección Reglas.",
                      systemImage: "list.bullet.clipboard")
                Label("Período de gracia: las primeras 3 reuniones no aplican multas.",
                      systemImage: "clock.badge.checkmark")
            }
        }
        .navigationTitle("Bienvenido a \(group.name)")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Entendido") { dismiss() }
            }
        }
    }
    .presentationDetents([.medium])
}
```

**Option B**: skip the overlay entirely, route straight to group home with a one-time inline banner ("Bienvenido. Las reglas viven en la pestaña Reglas." with a dismiss button) — closer to how Apple onboards new app surfaces.

- **Wordmark**: ❌ removed.
- **Brand color**: not applicable.

---

## Section 3: Transitions + flow logic

### Navigation primitive

Both flows use a **single `NavigationStack`** containing a `@ViewBuilder var stepView` that switches on `coordinator.currentStep`. Implementation in `OnboardingRootView.FounderFlow` (line 152-183) and `OnboardingRootView.InvitedFlow` (line 192-218).

This means:
- **No view is pushed** onto the stack — each step **replaces** the previous in place.
- **No native back-chevron** appears in the toolbar.
- **Swipe-back gesture from the screen edge** would attempt to pop, but since the stack has only one route, it pops out of the entire NavigationStack (… into nothing, since the parent is `AuthGate` rendering this as its body).
- **`.animation(.ruulMorph, value: coordinator.currentStep)`** is the only transition cue — a cross-fade-and-slide via custom spring.

The pattern is a **state machine** rendered into a single `NavigationStack` root, not a stack of pushed views. Apple-native equivalent for multi-step linear flows is **also** typically a single root with state-driven content (Setup Assistant works this way) — so the choice is OK, but the `NavigationStack` wrapper is misleading (it's not used for its push semantics).

### Path entry decision

`OnboardingRootView.bootstrap()` (line 57-93) routes:
1. **Restore mid-flow**: `OnboardingProgressManager.loadActive()` → either `FounderFlow` or `InvitedFlow` at the saved step.
2. **Deep-link pending invite**: `pendingInviteCode != nil` → `InvitedFlow` directly (skip path picker).
3. **Fresh start**: `OnboardingPathPickerView` → user picks create vs join.

### Mid-flow restore

On app cold-start, `bootstrap()` calls `coord.restore(from:)` which:
- Reads `founderStepRaw|invitedStepRaw` and projects legacy step ids onto current enum.
- Decodes `GroupDraft` JSON, `displayName`, `phoneE164`, `pendingInvitesJSON`.
- For founder: if `currentStep > .group`, re-fetches the created group (`groupRepo.get(createdGroupId)` or fallback to `listMine().sorted(byCreatedAt).first`).
- If group can't be restored, falls back to `.group` step.

### Completion paths

**Founder**:
- `advanceFromInvite()` → sends invites, marks `OnboardingCompletion`, transitions to `.confirm`, tracks `onboardingCompleted`.
- `skipInvite()` → marks `OnboardingCompletion`, transitions to `.confirm`, tracks.
- `ConfirmationView.task` → calls `coord.finishOnboarding()` which clears the SwiftData entity.
- User taps one of 3 CTAs → `onCompleted(.createFirstEvent | .inviteMore | .home)` → `AuthGate` re-evaluates and routes to `RootShell`.

**Invited**:
- `submitOTP()` success → marks `OnboardingCompletion`, marks invite used, transitions to `.tour`, tracks.
- `GroupTourOverlay.dismiss()` → `coord.finishOnboarding()` → `onCompleted()` → `AuthGate.refreshOnboardingState`.

### Edge cases

| Case | Current behavior |
|---|---|
| **User backgrounds app mid-flow** | `OnboardingProgress` entity persists; on next launch, `bootstrap()` restores. |
| **User force-quits at preset step before group created** | `createdGroupId == nil`, `currentStep == .preset` projects back to `.preset`. |
| **User force-quits at consent step after group created** | `currentStep == .consent`, group re-fetched via `createdGroupId`. |
| **Restore fails to fetch group** | Falls back to `.group` step, resets `createdGroupId = nil`. |
| **Deep link arrives mid-founder-flow** | Not handled. `pendingInviteCode` is only consumed when there's NO active progress (per bootstrap step 1 returning early on restore). |
| **User taps "Iniciar sesión" from FounderIdentityView** | Signs out anon session, marks `OnboardingCompletion`, AuthGate routes to `SignInView`. |
| **User taps "Ahora no" on InviteWelcomeView** | Calls `onDecline()` which equals `onCompleted()` — **routes to home as if onboarding succeeded.** Likely unintended. |
| **InviteCode invalid or expired** | `loadPreview()` catches, sets `error = .inviteCodeInvalid`. Flow shows error in `AsyncContentView.failed`. No retry button (per `AsyncContentView(onRetry: nil)`). User stuck. |
| **OTP attempts > 3** | `error = .otpTooManyAttempts`, screen shows "Demasiados intentos. Pide otro código." Resend button is still available after countdown. |
| **Cover image missing from `InvitePreview`** | `RuulCoverCatalog.cover(named:)` falls back to `.sunset`. |
| **Cancellation / "Back to picker"** | **No way back from flows.** Once in FounderFlow or InvitedFlow, the only exits are completion or "Iniciar sesión" (founder identity only) or "Ahora no" (invite welcome only). |

### Shared coordinator state

`OnboardingProgress` SwiftData entity is **the** persistence layer. Both coordinators read/write it via `OnboardingProgressPersisting` protocol. `OnboardingProgressManager` is production; `InMemoryOnboardingProgressStore` is tests-only.

`OnboardingCompletion` Keychain flag is the cross-flow signal to AuthGate. Set independently of `OnboardingProgress.clear()`.

---

## Section 4: Refactor priority recommendation (Wave 3 sequencing)

Categorized by structural-vs-mechanical, ordered for fast wins first.

### Tier 1 — Quick wins (token migration applies directly, low risk)

These screens are pure `OnboardingScreenTemplate` wrappers with a `Form`-shaped content area. Token migration (Wave 1 of audit §8) makes them ~80% native automatically.

1. **A5 `ConsentRulesView`** — simplest screen. Two `Text` + `VStack` of rows + a CTA. Replacing `RuulIconBadge` with `Label(systemImage:)` + dropping the card chrome reaches Apple-native with **~10-line diff**.
2. **A3 `GroupIdentityView`** — single text field + suggestion chips. Chips become `Button` rows in a Section.
3. **B2 `InvitedIdentityView`** — same shape as A2.
4. **A2 `FounderIdentityView`** — text field + avatar + sign-in escape. Avatar shrinks, escape becomes a Section button.
5. **B3 `InvitedVerifyView`** — phone field + footnote. Already close to native.
6. **B4 `InvitedOTPView`** — OTP field + resend + error states. `RuulOTPInput` stays as a domain wrapper.

### Tier 2 — Structural simplification (delete custom containers)

Screens that use multiple custom primitives layered. Need design pass + manual decisions.

7. **A6 `InviteMembersView`** — three card primitives (share-link, RuulActionableCard, manual entry sheet) → single `Form` with three Sections. Manual-entry sheet rewritten without `ModalSheetTemplate`.
8. **A4 `PresetPickerView`** — preset cards with `.ultraThinMaterial` + checkmark + 2pt stroke selection ring. Becomes a `Form` Section with selectable rows. Beta-flag filtering stays.
9. **A0 `OnboardingPathPickerView`** — two custom path buttons. Becomes a `List` with two `NavigationLink` rows.

### Tier 3 — Rebuild (the marketing surfaces)

Screens that need a **conceptual redesign**, not just token replacement, because the current layout assumes a SaaS marketing aesthetic.

10. **A1 `WelcomeView`** — drop the wordmark+`displayLarge` splash. Could be deleted entirely (route path-picker → A2 directly).
11. **A7 `ConfirmationView`** — strip the violet mesh background, replace `RuulButton(.glass)`, use a celebration pattern closer to Apple's "All set" screens.
12. **B5 `GroupTourOverlay`** — convert from custom overlay-card to a native `.sheet` with `.presentationDetents([.medium])`, OR drop entirely in favor of an inline banner on group home.
13. **B1 `InviteWelcomeView`** ⚠️ **highest blast radius** — full redesign. Drop ambient background, drop poster card aspect ratio + vignette, rebuild as a Calendar-invitation pattern (inset cover image as content, large-title group name, avatar stack, bottom-bar CTAs). Doctrine decision #4 mandates this change.

### Suggested PR ordering for Wave 3 onboarding session

```
PR #onboarding-1: OnboardingScreenTemplate + OnboardingStepContainer rebuild
                  (drop mesh param, swap RuulProgressBar for nothing or a
                   stepCount in nav title, render as standard
                   NavigationStack + Form-ready scaffold)
PR #onboarding-2: A5 ConsentRulesView native rebuild
PR #onboarding-3: A2 + B2 Identity views native rebuild
PR #onboarding-4: A3 GroupIdentity native rebuild
PR #onboarding-5: B3 + B4 phoneVerify + OTP native rebuild
PR #onboarding-6: A4 PresetPicker native rebuild
PR #onboarding-7: A6 InviteMembers native rebuild
PR #onboarding-8: A0 PathPicker native rebuild
PR #onboarding-9: A1 Welcome decision (delete or keep + simplify) and
                  A7 Confirmation rebuild
PR #onboarding-10: B5 GroupTourOverlay convert to sheet
PR #onboarding-11: B1 InviteWelcome full redesign (Calendar-invitation pattern)
```

PRs 1-8 are **mechanical** with Form/Section/List/native control swaps.
PRs 9-11 are **design changes** requiring founder review of new copy + structure.

---

## Section 5: Vocabulary sweep (per doctrine ban list)

**Doctrine bans**: capability, module, projection, atom, resource_type, trigger, consequence, rule shape, governance hierarchy, ledger.

User-facing copy across all 18 files is **already clean** of the ban list. Specifically reviewed:
- "regla" / "reglas" / "modo sugerencia" — allowed (rule is not banned, "rule shape" is).
- "multa" / "multas" — allowed (rules feature surface).
- "grupo", "miembros", "invitación", "código", "evento", "host", "reunión", "recordatorios" — all in the allowed list (people / activity / money / rules / schedule / access / history / ownership / participation).
- "Activo compartido", "Empezar de cero", "Reuniones recurrentes" — preset display names. Clean.

**No vocabulary violations** in onboarding. The architectural debt sits in `Resources` / `Group/GovernanceView` / `Profile/MyLedgerView` per audit §6 — not onboarding.

---

## Section 6: DEAD_CODE markers

### `Packages/RuulUI/Sources/RuulUI/Templates/OnboardingScreenTemplate.swift:18,29,42-54`

`OnboardingScreenTemplate.mesh: RuulMeshBackground.Variant` is accepted in the initializer, stored on the struct (`private let mesh:`), but **never read** in `var body`. The body only paints `Color.ruulBackground.ignoresSafeArea()` and ignores `mesh`. All 7 wrapped screens pass `mesh: .cool` or `mesh: .aqua` (or `.violet` in `TemplatesShowcaseView`), but the value has no rendering effect.

**Status**: DEAD_CODE. Remove the parameter and the `mesh` argument at all 7 call sites in onboarding views + the showcase.

### `Packages/RuulCore/Sources/RuulCore/PlatformModels/Identity/OnboardingRuleDraft.swift:46-149`

`OnboardingRuleDraft.defaults` defines 5 dinner-template rules statically. The only reference to the **type** `OnboardingRuleDraft` outside this file is in `Repositories/RuleRepository.swift` (for the type signature) and `ResourceWizardCoordinator.swift` / `RuleGovernanceCoordinator.swift` / `ResourceBuilder.swift` (as part of the rule-repository protocol). `.defaults` itself has **no call sites** (Grep confirms zero references).

Current onboarding flow seeds template rules **server-side** via `ruleRepo.seedTemplateRules(templateId:groupId:)` (see `FounderOnboardingCoordinator.swift:204-208`) which returns `[OnboardingRule]` (the live type), not `[OnboardingRuleDraft]`. The `.defaults` static was the pre-S1 source of seeded rules and is now superseded.

**Status**: DEAD_CODE. `OnboardingRuleDraft.defaults` (and possibly the entire `OnboardingRuleDraft.swift` file, pending verification that the protocol signatures actually need the type) is unused.

### `Packages/RuulFeatures/.../Onboarding/Founder/Coordinator/FounderOnboardingCoordinator.swift:62-64`

```swift
// `otp` is part of the legacy init signature but unused post S1.
// Kept so AppState's existing wiring compiles without refactor.
_ = otp
```

The `otp: any OTPService` parameter is taken and immediately discarded. Not technically dead code (parameter is part of the public API) but **dead parameter** — should be removed in a future cleanup PR with a parallel `AppState` refactor to drop the argument at the call site.

**Status**: vestigial parameter, not strictly DEAD_CODE but flagged for removal.

### `Packages/RuulFeatures/.../Onboarding/Founder/Views/GroupIdentityView.swift:37-43`

Comment block notes the cover picker was removed. `draft.coverImageName` stays `nil`. The remaining surface (`RuulCoverCatalog.cover(named:)` fallback to `.sunset`) is **live code**, but the comment serves as a marker that the founder cover-image flow was deliberately removed pre-Beta-1.

**Status**: not dead code, but documents a removed feature.

---

## Appendix A — File index

```
Shared/
  OnboardingRootView.swift             18  routes flows, mounts coordinators
  OnboardingPathPickerView.swift       17  Step 0 create-vs-join picker
  OnboardingProgressManager.swift      18  SwiftData + in-memory store
  OnboardingError.swift                52  LocalizedError enum
Founder/
  Coordinator/
    FounderOnboardingCoordinator.swift 21  @Observable state machine
  Views/
    WelcomeView.swift                  41  splash + wordmark
    FounderIdentityView.swift          139 name + avatar + sign-in escape
    GroupIdentityView.swift             69 group name + suggestion chips
    PresetPickerView.swift             126 3 preset cards + Beta filter
    ConsentRulesView.swift              80 read-only rule preview
    InviteMembersView.swift            257 share-link + contacts + manual + pending
    ConfirmationView.swift              65 celebration screen
Invited/
  Coordinator/
    InvitedOnboardingCoordinator.swift  6  @Observable state machine
  Views/
    InviteWelcomeView.swift            190 poster card + accept/decline
    InvitedIdentityView.swift           73 name + avatar
    InvitedVerifyView.swift             46 phone field
    InvitedOTPView.swift                80 6-digit OTP + resend countdown
    GroupTourOverlay.swift              91 modal welcome card
```

## Appendix B — Mount point

```
ios/Tandas/Shell/AuthGate.swift:72
    OnboardingRootView(pendingInviteCode: app.pendingInviteCode) { _ in
        Task {
            app.consumePendingInvite()
            await refreshOnboardingState()
            await app.refreshProfileAndGroups()
        }
    }
```

Branching:
- `isBootstrapping || !hasCheckedOnboarding` → `BootstrappingView` (wordmark splash).
- `session == nil` → `SignInView`.
- `hasActiveOnboarding || isFirstTimeAuth` → `OnboardingRootView`.
- otherwise → `RootShell`.

`OnboardingCompletion` Keychain flag is observed via `NotificationCenter` subscription on `OnboardingCompletion.didChangeNotification` so Keychain mutations cause an AuthGate re-render.
