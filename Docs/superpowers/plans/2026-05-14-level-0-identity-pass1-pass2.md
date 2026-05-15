# Level 0 Identity — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate Nivel 0 (cross-group identity) from Nivel 2 (group-scoped membership) in the Profile tab, kill the orphan SettingsSheet, and wire `profiles.timezone` / `profiles.locale` / phone-change / email-change to the FE.

**Architecture:** Two sequential passes. Pass 1 is a pure structural refactor (no BE, zero migrations) — rename `ProfileView` → `MyProfileView`, slim its responsibilities, absorb appearance + signout from the deleted `SettingsSheet`. Pass 2 wires existing-but-unexposed BE fields (`profiles.timezone`, `profiles.locale`, Supabase phone/email change OTP) and adds 4 new subscreens.

**Tech Stack:** SwiftUI (iOS 26 deployment target), Swift 6 strict concurrency, `@Observable` view models, supabase-swift 2.20+, Lefthook for codegen.

**Source spec:** `docs/superpowers/specs/2026-05-14-level-0-identity-redesign.md` (Pass 1 + Pass 2 sections only).

---

## File Structure

### Pass 1 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/ProfileCoordinator.swift` | **Modify** | Remove `fines`, `fineRepo`, derived stats. Slim to ~70 L |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/ProfileView.swift` | **Rename → `MyProfileView.swift`** | Drop statusHero, statTiles, groupScopeSection, GroupScopeContext, onOpenSettings. Absorb appearance picker + signOut from SettingsSheet |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/ProfileTab.swift` | **Modify** | Drop `groupScope` arg, drop `onOpenSettings`, inject `MyFinesCoordinator` for the cross-group fines pill |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/SettingsSheet.swift` | **DELETE** | Content absorbed into `MyProfileView` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/Views/SettingsTabView.swift` | **DELETE** | Wrapper no longer needed |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/` (the whole directory) | **DELETE** | Becomes empty after the two files above |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift` | **Modify** | Remove `case settings` from sheet route enum |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` | **Modify** | Remove the `.settings` sheet handler block |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift` | **Modify** | Remove `openSettings()` method |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift` | **Modify** | Remove `@State showSettings`, the sheet block, and the caller that sets it true |

### Pass 2 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ProfileRepository.swift` | **Modify** | Add `updateTimezone(_:)` + `updateLocale(_:)` to protocol + Live + Mock |
| `ios/Packages/RuulCore/Sources/RuulCore/Supabase/AuthService.swift` | **Modify** | Add `startPhoneChange/confirmPhoneChange` + `startEmailChange/confirmEmailChange` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/LanguagePickerView.swift` | **Create** | 5 BCP-47 options |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/TimezonePickerView.swift` | **Create** | Filterable IANA list |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/ChangePhoneFlow.swift` | **Create** | 2-step flow |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/ChangeEmailFlow.swift` | **Create** | 2-step flow |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/MyProfileView.swift` | **Modify** | Add `Identidad` + `Preferencias` sections + nav routing |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift` | **Modify** | Apply `.environment(\.locale, Locale(identifier: app.profile?.locale ?? "es-MX"))` to root content |

### Notes on testing

The SPM packages `RuulCore` and `RuulFeatures` **do not have test targets** (verified — `Package.swift` has no `.testTarget`). DoD per `CLAUDE.md` is: build clean in Xcode 16+ with no warnings, `xcodebuild test` at the app level passes, manual smoke in iOS 26 simulator.

This plan therefore uses **build + simulator smoke** as the primary verification gate. Inline `#Preview` blocks are added to new/changed views as a lightweight verification artifact. Do **not** create `Tests/` directories or new test targets in this plan — that's a separate scaffolding task and out of scope.

### A note on `MyFinesCrossGroupCoordinator` (spec correction)

The spec proposed creating `MyFinesCrossGroupCoordinator` (~80 L) for the cross-group fines aggregation. **This already exists** as `Features/Fines/Coordinator/MyFinesCoordinator.swift` — it uses `fineRepo.myFines(userId:)` + `groupsRepo.listMine()` and exposes `totalOutstanding`. We will reuse it. No new coordinator is created in this plan.

---

## Pass 1 — Structural separation (Tasks 1-5)

### Task 1: Slim `ProfileCoordinator` — remove fine ownership

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/ProfileCoordinator.swift`

**Why:** `ProfileCoordinator` currently owns `fines: [Fine]` and four derived stats (`totalOutstanding`, `paidThisMonth`, `totalFineCount`, `isAllClear`). All four are group-scoped (Nivel 2), not Nivel 0. The Profile tab will read cross-group totals from the existing `MyFinesCoordinator` instead.

- [ ] **Step 1: Replace the entire file with the slimmed version**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/ProfileCoordinator.swift`:

```swift
import Foundation
import Observation
import OSLog
import RuulUI
import RuulCore

/// Loads the user's own Profile (Nivel 0 — Identity, cross-group).
/// Fines and group-scoped derivations live in `MyFinesCoordinator`; this
/// coordinator no longer aggregates them.
@Observable
@MainActor
public final class ProfileCoordinator {
    public let userId: UUID
    private let profileRepo: any ProfileRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "profile")

    public var profile: Profile?
    public var isLoading: Bool = false
    public var isUploadingAvatar: Bool = false
    public var error: CoordinatorError?

    public init(userId: UUID, profileRepo: any ProfileRepository) {
        self.userId = userId
        self.profileRepo = profileRepo
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            self.profile = try await profileRepo.loadMine()
        } catch {
            log.warning("profile refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar tu perfil")
        }
    }

    public func clearError() { error = nil }

    public func updateDisplayName(_ newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = CoordinatorError(
                title: "Nombre vacío",
                message: "Tu nombre no puede estar vacío.",
                isRetryable: false
            )
            return
        }
        guard trimmed != profile?.displayName else { return }
        do {
            try await profileRepo.updateDisplayName(trimmed)
            await refresh()
        } catch {
            log.warning("updateDisplayName failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos guardar tu nombre")
        }
    }

    public func updateAvatar(data: Data, contentType: String) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        do {
            _ = try await profileRepo.updateAvatar(data: data, contentType: contentType)
            await refresh()
        } catch {
            log.warning("updateAvatar failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos subir tu foto")
        }
    }
}
```

- [ ] **Step 2: Update the one caller in `EditProfileSheet.swift`**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/EditProfileSheet.swift` line ~202. The existing call is:

```swift
let coord = ProfileCoordinator(
    userId: ...,
    profileRepo: ...,
    fineRepo: ...   // ← REMOVE THIS LINE
)
```

Remove the `fineRepo:` arg from the init call.

- [ ] **Step 3: Update the second caller in `RootShell.swift`**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift` line ~126. Same change — remove the `fineRepo:` arg from the `ProfileCoordinator(...)` call.

- [ ] **Step 4: Build to verify**

Run from project root:
```bash
xcodebuild -workspace ios/Tandas.xcworkspace -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -30
```

If `Tandas.xcworkspace` doesn't exist, use the project file:
```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`. If a caller in another file still passes `fineRepo:` to `ProfileCoordinator`, fix it the same way and rerun.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/ProfileCoordinator.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/EditProfileSheet.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift
git commit -m "$(cat <<'EOF'
refactor(profile): slim ProfileCoordinator to Nivel 0 only

Removes fines, fineRepo, and the four derived fine stats. Cross-group
fine aggregation already lives in MyFinesCoordinator and will be
consumed directly by the Profile tab in a follow-up.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 2: Rename `ProfileView` → `MyProfileView`, drop group-scoped UI, absorb appearance + signout

**Files:**
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/ProfileView.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/MyProfileView.swift`

**Why:** The current view mixes Nivel 0 (avatar, name) with Nivel 2 (statusHero based on group fines, statTiles, "Este grupo" section). It also depends on a separate `SettingsSheet` for appearance + signout. The redesigned view shows only cross-group identity content and absorbs settings inline.

- [ ] **Step 1: Delete the old `ProfileView.swift`**

```bash
rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/ProfileView.swift
```

- [ ] **Step 2: Write the new `MyProfileView.swift`**

Create `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/MyProfileView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Tab "Yo" — Nivel 0 (Identity, cross-group). Shows the user's own
/// profile and cross-group activity entry points only. No group-active
/// state leaks into this view.
///
/// Layout:
///   Hero (avatar + name + "Miembro de N grupos")
///   Tu actividad (Mis multas, Mis movimientos, Actividad del grupo)
///   Ajustes (Editar perfil)
///   Apariencia (theme picker, inline)
///   Cerrar sesión
public struct MyProfileView: View {
    @State var coordinator: ProfileCoordinator
    @Environment(AppState.self) private var app
    @AppStorage("ruul_appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue

    public let onOpenMyFines: () -> Void
    public let onOpenHistory: () -> Void
    public let onEditProfile: () -> Void
    public let onSignOut: () -> Void
    public var onOpenMyLedger: (() -> Void)? = nil

    /// Cross-group outstanding fines pill (read from MyFinesCoordinator).
    /// nil while loading or when zero.
    public var outstandingPillAmount: Decimal?

    public init(
        coordinator: ProfileCoordinator,
        onOpenMyFines: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onEditProfile: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
        onOpenMyLedger: (() -> Void)? = nil,
        outstandingPillAmount: Decimal? = nil
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onOpenMyFines = onOpenMyFines
        self.onOpenHistory = onOpenHistory
        self.onEditProfile = onEditProfile
        self.onSignOut = onSignOut
        self.onOpenMyLedger = onOpenMyLedger
        self.outstandingPillAmount = outstandingPillAmount
    }

    private var appearance: Binding<AppearanceOption> {
        Binding(
            get: { AppearanceOption(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.profile == nil {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.lg)
                        .transition(.opacity)
                } else if coordinator.profile == nil && coordinator.isLoading {
                    RuulLoadingState().transition(.opacity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                            hero
                            activitySection
                            settingsSection
                            appearanceSection
                            signOutButton
                        }
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.xs)
                        .padding(.bottom, RuulSpacing.s12)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await coordinator.refresh() }
                    .transition(.opacity)
                }
            }
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
            .animation(.linear(duration: RuulDuration.fast), value: coordinator.profile?.id)
        }
        .task { await coordinator.refresh() }
    }

    // MARK: Hero (avatar + name + cross-group meta)

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: coordinator.profile?.displayName ?? "?",
                imageURL: coordinator.profile?.avatarUrl.flatMap(URL.init(string:)),
                size: .large
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.profile?.displayName ?? "—")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(membershipMeta)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, RuulSpacing.md)
    }

    private var membershipMeta: String {
        let count = app.groups.count
        if count == 0 { return "Sin grupos" }
        if count == 1 { return "Miembro de 1 grupo" }
        return "Miembro de \(count) grupos"
    }

    // MARK: Sections

    private var activitySection: some View {
        sectionContainer(title: "TU ACTIVIDAD") {
            navRow(icon: "creditcard", label: "Mis multas", trailing: { outstandingPill }, action: onOpenMyFines)
            if let onOpenMyLedger {
                divider
                navRow(icon: "arrow.left.arrow.right", label: "Mis movimientos", trailing: { EmptyView() }, action: onOpenMyLedger)
            }
            divider
            navRow(icon: "clock.arrow.circlepath", label: "Actividad del grupo", trailing: { EmptyView() }, action: onOpenHistory)
        }
    }

    private var settingsSection: some View {
        sectionContainer(title: "AJUSTES") {
            navRow(icon: "pencil", label: "Editar perfil", trailing: { EmptyView() }, action: onEditProfile)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("APARIENCIA")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            HStack(spacing: RuulSpacing.xs) {
                ForEach(AppearanceOption.allCases) { option in
                    Button {
                        appearance.wrappedValue = option
                    } label: {
                        VStack(spacing: RuulSpacing.xxs) {
                            Image(systemName: option.systemImage)
                                .ruulTextStyle(RuulTypography.titleMedium)
                                .accessibilityHidden(true)
                            Text(option.label)
                                .ruulTextStyle(RuulTypography.callout)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.md)
                        .foregroundStyle(
                            appearance.wrappedValue == option
                                ? Color.ruulTextPrimary
                                : Color.ruulTextSecondary
                        )
                        .background(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .fill(
                                    appearance.wrappedValue == option
                                        ? Color.ruulBackgroundRecessed
                                        : Color.ruulSurface
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .stroke(
                                    appearance.wrappedValue == option
                                        ? Color.ruulBorderStrong
                                        : Color.ruulSeparator,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: appearance.wrappedValue)
                }
            }
        }
    }

    @ViewBuilder
    private var outstandingPill: some View {
        if let amount = outstandingPillAmount, amount > 0 {
            Text(amountFormatted(amount))
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulWarning)
        }
    }

    private var signOutButton: some View {
        Button(action: onSignOut) {
            Text("Cerrar sesión")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulNegative)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: Reusable section + row

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, 56)
    }

    @ViewBuilder
    private func navRow<Trailing: View>(
        icon: String,
        label: String,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void,
        destructive: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .ruulTextStyle(RuulTypography.subheadMedium)
                    .foregroundStyle(destructive ? Color.ruulNegative : Color.ruulTextSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(label)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(destructive ? Color.ruulNegative : Color.ruulTextPrimary)
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.captionBold)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func amountFormatted(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
```

- [ ] **Step 3: Build — expect failures in callers**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -30
```

Expected failures:
- `ProfileTab.swift` references `ProfileView(...)` (not `MyProfileView`)
- `SettingsTabView.swift` references `ProfileView(...)` and `ProfileView.GroupScopeContext`

These are fixed in Tasks 3 + 4. Do NOT fix them in this task.

- [ ] **Step 4: Commit (with broken build — explained in commit message)**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/
git commit -m "$(cat <<'EOF'
refactor(profile): rename ProfileView → MyProfileView, drop group scope

New MyProfileView is Nivel 0-only (cross-group identity). Removes
statusHero, statTiles, GroupScopeContext, and the onOpenSettings
callback (settings absorbed inline). Build is broken until ProfileTab
and SettingsTabView are updated/deleted in the next two tasks.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 3: Update `ProfileTab` to use `MyProfileView` + inject `MyFinesCoordinator`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/ProfileTab.swift`

**Why:** `ProfileTab` is the entry point for the "Yo" tab. It must (a) reference the renamed view, (b) drop the now-deleted `groupScope` arg, (c) drop `onOpenSettings` (settings inline now), and (d) read the cross-group outstanding amount from `MyFinesCoordinator` to power the pill.

- [ ] **Step 1: Replace `ProfileTab.swift` entirely**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/ProfileTab.swift`:

```swift
import SwiftUI
import RuulCore

/// Thin tab wrapper for "Yo" (Nivel 0). Embeds MyProfileView inside a
/// NavigationStack and forwards navigation to the RootRouter.
@MainActor
public struct ProfileTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let profileCoordinator: ProfileCoordinator?
    let myFinesCoordinator: MyFinesCoordinator?

    public init(profile: ProfileCoordinator?, myFines: MyFinesCoordinator?) {
        self.profileCoordinator = profile
        self.myFinesCoordinator = myFines
    }

    public var body: some View {
        NavigationStack {
            if let coord = profileCoordinator {
                MyProfileView(
                    coordinator: coord,
                    onOpenMyFines: { router.openSanciones() },
                    onOpenHistory: { router.selectTab(.home) },
                    onEditProfile: { router.openEditProfile() },
                    onSignOut: {
                        Task { try? await app.signOut() }
                    },
                    outstandingPillAmount: myFinesCoordinator?.totalOutstanding
                )
                .environment(app)
                .task { await myFinesCoordinator?.refresh() }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
```

- [ ] **Step 2: Find every `ProfileTab(profile:` caller and update the signature**

```bash
grep -rn "ProfileTab(profile:" ios/Packages ios/Tandas --include='*.swift' 2>/dev/null | grep -v "\.build"
```

Each caller currently looks like `ProfileTab(profile: someCoord)`. Update to `ProfileTab(profile: someCoord, myFines: app.myFinesCoordinator)` — confirm the AppState property name by searching `grep -n "myFines" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/AppState.swift` (expected: `app.myFinesCoordinator` or similar). If AppState doesn't already expose it, build a `MyFinesCoordinator` inline at the call site using the same constructor as `MyFinesView` already does.

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -30
```

Expected: only `SettingsTabView` errors remain. Those are fixed in Task 4.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/ProfileTab.swift \
        $(grep -rln "ProfileTab(profile:" ios/Packages ios/Tandas --include='*.swift' 2>/dev/null | grep -v "\.build")
git commit -m "$(cat <<'EOF'
refactor(shell): wire ProfileTab to MyProfileView + cross-group fines

ProfileTab now injects MyFinesCoordinator alongside ProfileCoordinator
and forwards its totalOutstanding to MyProfileView's pill. Drops the
groupScope and onOpenSettings parameters that died with SettingsTabView.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 4: Delete `SettingsSheet`, `SettingsTabView`, the entire `Settings/` folder, and clean up shell + Home callers

**Files:**
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/SettingsSheet.swift`
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/Views/SettingsTabView.swift`
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/` (the now-empty directory)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift` (line ~111)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` (line ~140-144)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift` (line ~169)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift` (lines ~38, 106-107, 189)

**Why:** Settings as a separate sheet/tab no longer exists. The shell route, the router method, the sheet handler, and the Home tab's gear-button trigger all become dead code.

- [ ] **Step 1: Delete the two Settings files and the empty directory**

```bash
rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/SettingsSheet.swift
rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/Views/SettingsTabView.swift
rmdir ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/Views \
      ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings
```

- [ ] **Step 2: Remove `case settings` from `RootShellState.swift`**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift`. Find the line:

```swift
case settings               // SettingsSheet (global account settings)
```

Delete that single line.

- [ ] **Step 3: Remove the `.settings` sheet block from `RootShellSheets.swift`**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift`. Find this block (around line 140):

```swift
// MARK: Settings sheet
.sheet(isPresented: boolBinding(for: .settings)) {
    SettingsSheet()
        .ruulSheetChrome(detents: [.medium, .large])
}
```

Delete the entire block including the `// MARK:` comment.

- [ ] **Step 4: Remove `openSettings()` from `RootRouter.swift`**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift`. Find:

```swift
public func openSettings() {
    // ...body...
}
```

Delete the entire method.

- [ ] **Step 5: Remove the gear-button settings flow from `HomeView.swift`**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift`:

  a. Delete line ~38: `@State private var showSettings: Bool = false`
  b. Delete the `.sheet(isPresented: $showSettings) { SettingsSheet() }` block (lines ~106-107 + closing brace)
  c. Find the button at ~line 189 that does `showSettings = true`. Replace the action body with a tab switch:
     ```swift
     // Was: showSettings = true
     // Now: profile *is* settings; jump to the Profile tab.
     router.selectTab(.profile)
     ```
     The exact tab enum case must match what's defined in `RootShellState.swift` — verify with `grep -n "enum.*Tab\|case profile\|case yo" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift`. If the gear button doesn't have a `router` reference in scope, inject `@Environment(RootRouter.self) private var router` at the top of `HomeView`.

- [ ] **Step 6: Build to verify clean**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED` and no warnings about unused `SettingsTabView` references.

- [ ] **Step 7: Commit**

```bash
git add -A ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Settings/ \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Home/HomeView.swift
git commit -m "$(cat <<'EOF'
refactor(shell): remove SettingsSheet + SettingsTabView entirely

Their content is absorbed into MyProfileView. Removes the `.settings`
shell route, the openSettings() router method, the sheet handler in
RootShellSheets, and the gear button flow in HomeView. The gear button
now opens the Profile tab directly.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 5: Smoke verification in iOS 26 simulator

**Files:** None (verification only).

**Why:** CLAUDE.md DoD includes "functional smoke en simulador iOS 26". Verify the Pass 1 outcome before moving to Pass 2.

- [ ] **Step 1: Boot simulator and install the app**

```bash
xcrun simctl boot 'iPhone 17 Pro' 2>/dev/null || true
xcrun simctl list devices | grep -E 'iPhone 17.*Booted' | head -3
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet build 2>&1 | tail -10
```

If "iPhone 17 Pro" isn't installed, swap for whichever iOS 26 device is available: `xcrun simctl list devicetypes | grep iPhone`.

- [ ] **Step 2: Launch and verify the Profile tab**

Open the simulator manually (or `xcrun simctl launch booted com.josejmizrahi.ruul`) and verify:

  1. Tap the "Yo" / Profile tab
  2. **No `statusHero`** ("TODO AL CORRIENTE" / "$300 PENDIENTE") at the top — should be only avatar + name + "Miembro de N grupos"
  3. **No "Este grupo" section** at the bottom
  4. Sections visible: `TU ACTIVIDAD`, `AJUSTES`, `APARIENCIA`, signout button
  5. Apariencia segmented control changes theme live
  6. "Cerrar sesión" button signs out (may need to sign back in to continue)

- [ ] **Step 3: Capture a screenshot for the PR**

```bash
xcrun simctl io booted screenshot /tmp/myprofile-pass1.png
```

- [ ] **Step 4: Tag this commit point as the Pass 1 milestone**

```bash
git log --oneline -5
git tag -a level0-pass1-complete -m "Level 0 redesign — Pass 1 (structural separation) complete"
```

If you don't want to tag, skip the tag step. Either way, no commit needed for verification.

---

## Pass 2 — Wire-up of `profiles.timezone`, `profiles.locale`, phone/email change (Tasks 6-10)

### Task 6: Extend `ProfileRepository` with `updateTimezone` + `updateLocale`

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ProfileRepository.swift`

**Why:** `LiveProfileRepository.loadMine()` already SELECTs `timezone, locale`, but no method exists to write them. RLS `profiles_self_write` (mig 00001) allows the update. Both fields are already in the `Profile` Swift model and DB schema (defaults seeded by mig 00173).

- [ ] **Step 1: Add the two methods to the protocol and both implementations**

Open `ios/Packages/RuulCore/Sources/RuulCore/Repositories/ProfileRepository.swift`. Replace the entire file:

```swift
import Foundation
import Supabase

public protocol ProfileRepository: Actor {
    func loadMine() async throws -> Profile
    func updateDisplayName(_ name: String) async throws
    func updateAvatar(data: Data, contentType: String) async throws -> URL
    /// IANA timezone (e.g., "America/Mexico_City"). RLS allows self-write.
    func updateTimezone(_ tz: String) async throws
    /// BCP-47 locale tag (e.g., "es-MX"). RLS allows self-write.
    func updateLocale(_ locale: String) async throws
}

public actor MockProfileRepository: ProfileRepository {
    private var _profile: Profile

    public init(seed: Profile = Profile(id: UUID(), displayName: "", avatarUrl: nil, phone: nil)) {
        self._profile = seed
    }

    public func loadMine() async throws -> Profile { _profile }

    public func updateDisplayName(_ name: String) async throws {
        _profile.displayName = name
    }

    public func updateAvatar(data: Data, contentType: String) async throws -> URL {
        let url = URL(string: "https://example.test/avatars/\(_profile.id.uuidString.lowercased()).jpg")!
        _profile.avatarUrl = url.absoluteString
        return url
    }

    public func updateTimezone(_ tz: String) async throws {
        _profile.timezone = tz
    }

    public func updateLocale(_ locale: String) async throws {
        _profile.locale = locale
    }
}

public actor LiveProfileRepository: ProfileRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) { self.client = client }

    public func loadMine() async throws -> Profile {
        let userId = try await client.auth.session.user.id
        let row: Profile = try await client
            .from("profiles")
            .select("id, display_name, avatar_url, phone, timezone, locale")
            .eq("id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        return row
    }

    public func updateDisplayName(_ name: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("profiles")
            .update(["display_name": name])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }

    public func updateAvatar(data: Data, contentType: String) async throws -> URL {
        let userId = try await client.auth.session.user.id
        let ext = Self.fileExtension(for: contentType)
        let ts = Int(Date.now.timeIntervalSince1970)
        let path = "\(userId.uuidString.lowercased())/avatar-\(ts).\(ext)"

        _ = try await client.storage
            .from("avatars")
            .upload(
                path,
                data: data,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: contentType,
                    upsert: true
                )
            )

        let publicURL = try client.storage.from("avatars").getPublicURL(path: path)

        try await client
            .from("profiles")
            .update(["avatar_url": publicURL.absoluteString])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()

        return publicURL
    }

    public func updateTimezone(_ tz: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("profiles")
            .update(["timezone": tz])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }

    public func updateLocale(_ locale: String) async throws {
        let userId = try await client.auth.session.user.id
        try await client
            .from("profiles")
            .update(["locale": locale])
            .eq("id", value: userId.uuidString.lowercased())
            .execute()
    }

    private static func fileExtension(for contentType: String) -> String {
        switch contentType.lowercased() {
        case "image/jpeg", "image/jpg":  return "jpg"
        case "image/png":                return "png"
        case "image/webp":               return "webp"
        case "image/heic":               return "heic"
        case "image/heif":               return "heif"
        default:                         return "jpg"
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Repositories/ProfileRepository.swift
git commit -m "$(cat <<'EOF'
feat(profile): expose updateTimezone + updateLocale on ProfileRepository

profiles.timezone and profiles.locale already loaded by loadMine() but
were write-only-via-DB until now. RLS profiles_self_write authorizes
the new mutations. Used by upcoming LanguagePickerView and
TimezonePickerView subscreens.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 7: Create `LanguagePickerView` and apply locale at the shell

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/LanguagePickerView.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift`

**Why:** Lets users pick their BCP-47 locale; the app re-renders strings via the `\.locale` environment.

- [ ] **Step 1: Create the picker view**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/LanguagePickerView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct LanguagePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    public init() {}

    /// Beta 1 supported locales. Add new ones here once Localizable.strings
    /// has the corresponding key set verified.
    public static let supported: [(code: String, label: String)] = [
        ("es-MX", "Español (México)"),
        ("es-ES", "Español (España)"),
        ("en-US", "English (US)"),
        ("pt-BR", "Português (Brasil)"),
        ("fr-FR", "Français")
    ]

    private var current: String { app.profile?.locale ?? "es-MX" }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Self.supported, id: \.code) { entry in
                    Button {
                        Task { await select(entry.code) }
                    } label: {
                        HStack {
                            Text(entry.label)
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Spacer()
                            if entry.code == current {
                                Image(systemName: "checkmark")
                                    .ruulTextStyle(RuulTypography.subheadMedium)
                                    .foregroundStyle(Color.ruulAccent)
                            }
                        }
                        .padding(RuulSpacing.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    if entry.code != Self.supported.last?.code {
                        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .padding(RuulSpacing.lg)

            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(.horizontal, RuulSpacing.lg)
            }
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .navigationTitle("Idioma")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ code: String) async {
        guard code != current else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            try await app.profileRepo.updateLocale(code)
            await app.refreshProfile()
            dismiss()
        } catch {
            self.error = "No pudimos guardar tu idioma. Intenta de nuevo."
        }
    }
}
```

NOTE: This relies on `AppState.profileRepo: any ProfileRepository` and `AppState.refreshProfile()` existing. Confirm with `grep -n "profileRepo\|refreshProfile" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/AppState.swift`. If the property name differs, adjust the call site. If `refreshProfile()` doesn't exist, replace with `await app.profileCoordinator?.refresh()` (whichever holds the canonical Profile).

- [ ] **Step 2: Apply locale at the shell**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift`. Find the root `body` view (the outermost `TabView` or its wrapper). Add the modifier:

```swift
.environment(\.locale, Locale(identifier: app.profile?.locale ?? "es-MX"))
```

Place it as the **last** modifier on the root content so changes propagate to all children.

- [ ] **Step 3: Build**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/LanguagePickerView.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShell.swift
git commit -m "$(cat <<'EOF'
feat(profile): LanguagePickerView + shell locale environment

5 BCP-47 options. Tap writes profiles.locale via ProfileRepository;
shell propagates the choice through \\.locale. Wiring into MyProfileView
arrives in the section task at the end of Pass 2.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 8: Create `TimezonePickerView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/TimezonePickerView.swift`

**Why:** Lets the user override the implicit `TimeZone.current` so notifications fire at the user's expected wall-clock time even when traveling.

- [ ] **Step 1: Create the picker view**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/TimezonePickerView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct TimezonePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var saving = false
    @State private var error: String?

    public init() {}

    private var allZones: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }
    private var current: String { app.profile?.timezone ?? TimeZone.current.identifier }

    private var filteredZones: [String] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return allZones }
        let q = query.lowercased()
        return allZones.filter { $0.lowercased().contains(q) }
    }

    public var body: some View {
        List {
            ForEach(filteredZones, id: \.self) { tz in
                Button {
                    Task { await select(tz) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tz)
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Text(offsetLabel(for: tz))
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                        }
                        Spacer()
                        if tz == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.ruulAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Buscar zona")
        .background(Color.ruulBackground.ignoresSafeArea())
        .navigationTitle("Zona horaria")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(RuulSpacing.md)
                    .background(Color.ruulSurface, in: Capsule())
            }
        }
    }

    private func offsetLabel(for tz: String) -> String {
        guard let zone = TimeZone(identifier: tz) else { return "" }
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs((seconds % 3600) / 60)
        let sign = seconds >= 0 ? "+" : "-"
        return String(format: "GMT%@%02d:%02d", sign, abs(hours), minutes)
    }

    private func select(_ tz: String) async {
        guard tz != current else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            try await app.profileRepo.updateTimezone(tz)
            await app.refreshProfile()
            dismiss()
        } catch {
            self.error = "No pudimos guardar tu zona horaria."
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/TimezonePickerView.swift
git commit -m "$(cat <<'EOF'
feat(profile): TimezonePickerView (filterable IANA list with offset label)

Tap writes profiles.timezone via ProfileRepository. Wiring into
MyProfileView arrives in the section task at the end of Pass 2.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 9: Add phone/email change to `AuthService` + `ChangePhoneFlow` + `ChangeEmailFlow`

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Supabase/AuthService.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/ChangePhoneFlow.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/ChangeEmailFlow.swift`

**Why:** `auth.users.phone` and `auth.users.email` can change via OTP; the existing `on_auth_user_phone_sync` trigger (mig 00001 + earlier) mirrors `phone` to `profiles.phone` automatically.

**Pre-requisite verification (before writing code):**

  1. Confirm the SDK supports `OtpType.phoneChange` and `.emailChange`:
     ```bash
     grep -rn "phoneChange\|emailChange" ios/Packages/RuulCore/.build/checkouts/supabase-swift/Sources 2>/dev/null | head -5
     ```
     If absent, the flow needs a server-side workaround (edge function). Document the finding and stop this task — escalate before continuing.
  2. Confirm `client.auth.update(user:)` accepts phone/email:
     ```bash
     grep -rn "func update.*UserAttributes" ios/Packages/RuulCore/.build/checkouts/supabase-swift/Sources 2>/dev/null | head -5
     ```

If both checks pass, proceed.

- [ ] **Step 1: Add the four methods to `AuthService`**

Open `ios/Packages/RuulCore/Sources/RuulCore/Supabase/AuthService.swift`. Add to the `AuthService` protocol:

```swift
func startPhoneChange(_ newPhone: String) async throws
func confirmPhoneChange(otp: String, newPhone: String) async throws
func startEmailChange(_ newEmail: String) async throws
func confirmEmailChange(otp: String, newEmail: String) async throws
```

In `LiveAuthService`:

```swift
public func startPhoneChange(_ newPhone: String) async throws {
    _ = try await client.auth.update(user: UserAttributes(phone: newPhone))
}

public func confirmPhoneChange(otp: String, newPhone: String) async throws {
    try await client.auth.verifyOTP(phone: newPhone, token: otp, type: .phoneChange)
}

public func startEmailChange(_ newEmail: String) async throws {
    _ = try await client.auth.update(user: UserAttributes(email: newEmail))
}

public func confirmEmailChange(otp: String, newEmail: String) async throws {
    try await client.auth.verifyOTP(email: newEmail, token: otp, type: .emailChange)
}
```

In `MockAuthService` add no-op stubs that update the cached `phone`/`email` on the in-memory user.

NOTE: Exact method names depend on the supabase-swift 2.20.x API. If `verifyOTP` has a different signature in the installed version, adapt — check `grep -n "func verifyOTP" ios/Packages/RuulCore/.build/checkouts/supabase-swift/Sources/Auth/AuthClient.swift`.

- [ ] **Step 2: Create `ChangePhoneFlow.swift`**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/ChangePhoneFlow.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct ChangePhoneFlow: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .enterPhone
    @State private var newPhone = ""
    @State private var otp = ""
    @State private var sending = false
    @State private var error: String?

    private enum Step { case enterPhone, enterOTP }

    public init() {}

    public var body: some View {
        NavigationStack {
            switch step {
            case .enterPhone: enterPhoneStep
            case .enterOTP:   enterOTPStep
            }
        }
    }

    private var enterPhoneStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Tu nuevo número")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            TextField("+52 55 1234 5678", text: $newPhone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            if let error { errorLabel(error) }
            Spacer()
            Button("Enviar código") { Task { await sendOTP() } }
                .buttonStyle(.borderedProminent)
                .disabled(sending || newPhone.isEmpty)
        }
        .padding(RuulSpacing.lg)
        .navigationTitle("Cambiar teléfono")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { dismiss() } } }
    }

    private var enterOTPStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Código enviado a \(newPhone)")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            TextField("000000", text: $otp)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            if let error { errorLabel(error) }
            Spacer()
            Button("Confirmar") { Task { await confirm() } }
                .buttonStyle(.borderedProminent)
                .disabled(sending || otp.count < 4)
        }
        .padding(RuulSpacing.lg)
        .navigationTitle("Verificar código")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func errorLabel(_ msg: String) -> some View {
        Text(msg)
            .ruulTextStyle(RuulTypography.footnote)
            .foregroundStyle(Color.ruulNegative)
    }

    private func sendOTP() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await app.authService.startPhoneChange(newPhone)
            step = .enterOTP
        } catch {
            self.error = "No pudimos enviar el código. Verifica el número."
        }
    }

    private func confirm() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await app.authService.confirmPhoneChange(otp: otp, newPhone: newPhone)
            await app.refreshProfile()
            dismiss()
        } catch {
            self.error = "Código inválido."
        }
    }
}
```

- [ ] **Step 3: Create `ChangeEmailFlow.swift`**

Write the email mirror at `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/ChangeEmailFlow.swift`. The structure is identical to `ChangePhoneFlow` with these substitutions:

  - `newPhone` → `newEmail`
  - `.telephoneNumber` → `.emailAddress`
  - `.phonePad` → `.emailAddress`
  - `startPhoneChange` → `startEmailChange`
  - `confirmPhoneChange(otp:newPhone:)` → `confirmEmailChange(otp:newEmail:)`
  - Title: "Cambiar correo" / "Verificar código"

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct ChangeEmailFlow: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .enterEmail
    @State private var newEmail = ""
    @State private var otp = ""
    @State private var sending = false
    @State private var error: String?

    private enum Step { case enterEmail, enterOTP }

    public init() {}

    public var body: some View {
        NavigationStack {
            switch step {
            case .enterEmail: enterEmailStep
            case .enterOTP:   enterOTPStep
            }
        }
    }

    private var enterEmailStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Tu nuevo correo")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            TextField("nombre@dominio.com", text: $newEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            if let error {
                Text(error).ruulTextStyle(RuulTypography.footnote).foregroundStyle(Color.ruulNegative)
            }
            Spacer()
            Button("Enviar código") { Task { await sendOTP() } }
                .buttonStyle(.borderedProminent)
                .disabled(sending || newEmail.isEmpty)
        }
        .padding(RuulSpacing.lg)
        .navigationTitle("Cambiar correo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { dismiss() } } }
    }

    private var enterOTPStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            Text("Código enviado a \(newEmail)")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            TextField("000000", text: $otp)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .padding(RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
            if let error {
                Text(error).ruulTextStyle(RuulTypography.footnote).foregroundStyle(Color.ruulNegative)
            }
            Spacer()
            Button("Confirmar") { Task { await confirm() } }
                .buttonStyle(.borderedProminent)
                .disabled(sending || otp.count < 4)
        }
        .padding(RuulSpacing.lg)
        .navigationTitle("Verificar código")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendOTP() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await app.authService.startEmailChange(newEmail)
            step = .enterOTP
        } catch {
            self.error = "No pudimos enviar el código. Verifica el correo."
        }
    }

    private func confirm() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await app.authService.confirmEmailChange(otp: otp, newEmail: newEmail)
            await app.refreshProfile()
            dismiss()
        } catch {
            self.error = "Código inválido."
        }
    }
}
```

NOTE: `app.authService` must be exposed. If not, add a public computed property to `AppState` returning the configured `LiveAuthService`. Confirm with `grep -n "authService" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/AppState.swift`.

- [ ] **Step 4: Build**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Supabase/AuthService.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/ChangePhoneFlow.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/ChangeEmailFlow.swift
git commit -m "$(cat <<'EOF'
feat(auth): phone/email change OTP flows

Adds startPhoneChange / confirmPhoneChange / startEmailChange /
confirmEmailChange to AuthService backed by supabase-swift's
verifyOTP(.phoneChange|.emailChange). Two SwiftUI flows wire them
end-to-end with 2-step entry. profiles.phone is mirrored automatically
by the existing on_auth_user_phone_sync trigger.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 10: Add `Identidad` + `Preferencias` sections to `MyProfileView` and wire navigation

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/MyProfileView.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/ProfileTab.swift` (add nav destinations)

**Why:** Wires the four subscreens into the main Profile UI.

- [ ] **Step 1: Add `Identidad` and `Preferencias` sections to `MyProfileView.swift`**

In `MyProfileView.swift`, add four new stored properties (after `outstandingPillAmount`):

```swift
public var onChangePhone: (() -> Void)?
public var onChangeEmail: (() -> Void)?
public var onPickLanguage: (() -> Void)?
public var onPickTimezone: (() -> Void)?
```

Update the explicit `init` to accept all four with `nil` defaults. The complete new init signature should be:

```swift
public init(
    coordinator: ProfileCoordinator,
    onOpenMyFines: @escaping () -> Void,
    onOpenHistory: @escaping () -> Void,
    onEditProfile: @escaping () -> Void,
    onSignOut: @escaping () -> Void,
    onOpenMyLedger: (() -> Void)? = nil,
    outstandingPillAmount: Decimal? = nil,
    onChangePhone: (() -> Void)? = nil,
    onChangeEmail: (() -> Void)? = nil,
    onPickLanguage: (() -> Void)? = nil,
    onPickTimezone: (() -> Void)? = nil
) {
    self._coordinator = State(initialValue: coordinator)
    self.onOpenMyFines = onOpenMyFines
    self.onOpenHistory = onOpenHistory
    self.onEditProfile = onEditProfile
    self.onSignOut = onSignOut
    self.onOpenMyLedger = onOpenMyLedger
    self.outstandingPillAmount = outstandingPillAmount
    self.onChangePhone = onChangePhone
    self.onChangeEmail = onChangeEmail
    self.onPickLanguage = onPickLanguage
    self.onPickTimezone = onPickTimezone
}
```

Then add the new sections to the `body`'s `VStack` between `hero` and `activitySection`:

```swift
identitySection
preferencesSection
```

And add these section views (alongside the existing `activitySection`, `settingsSection`, `appearanceSection`):

```swift
private var identitySection: some View {
    sectionContainer(title: "IDENTIDAD") {
        navRow(
            icon: "phone",
            label: "Teléfono",
            trailing: { trailingValue(coordinator.profile?.phone ?? "—") },
            action: { onChangePhone?() }
        )
        divider
        navRow(
            icon: "envelope",
            label: "Correo",
            trailing: { trailingValue(app.session?.user.email ?? "—") },
            action: { onChangeEmail?() }
        )
    }
}

private var preferencesSection: some View {
    sectionContainer(title: "PREFERENCIAS") {
        navRow(
            icon: "globe",
            label: "Idioma",
            trailing: { trailingValue(localeLabel(coordinator.profile?.locale)) },
            action: { onPickLanguage?() }
        )
        divider
        navRow(
            icon: "clock",
            label: "Zona horaria",
            trailing: { trailingValue(coordinator.profile?.timezone ?? "—") },
            action: { onPickTimezone?() }
        )
    }
}

private func trailingValue(_ s: String) -> some View {
    Text(s)
        .ruulTextStyle(RuulTypography.caption)
        .foregroundStyle(Color.ruulTextSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
}

private func localeLabel(_ code: String?) -> String {
    guard let code, let entry = LanguagePickerView.supported.first(where: { $0.code == code }) else { return "—" }
    return entry.label
}
```

- [ ] **Step 2: Wire navigation in `ProfileTab.swift`**

Replace the `MyProfileView(...)` call in `ProfileTab.swift` with:

```swift
MyProfileView(
    coordinator: coord,
    onOpenMyFines: { router.openSanciones() },
    onOpenHistory: { router.selectTab(.home) },
    onEditProfile: { router.openEditProfile() },
    onSignOut: { Task { try? await app.signOut() } },
    outstandingPillAmount: myFinesCoordinator?.totalOutstanding,
    onChangePhone: { showChangePhone = true },
    onChangeEmail: { showChangeEmail = true },
    onPickLanguage: { path.append(ProfileNav.language) },
    onPickTimezone: { path.append(ProfileNav.timezone) }
)
.navigationDestination(for: ProfileNav.self) { dest in
    switch dest {
    case .language: LanguagePickerView()
    case .timezone: TimezonePickerView()
    }
}
.sheet(isPresented: $showChangePhone) { ChangePhoneFlow() }
.sheet(isPresented: $showChangeEmail) { ChangeEmailFlow() }
```

Add to the `ProfileTab` struct:

```swift
@State private var path = NavigationPath()
@State private var showChangePhone = false
@State private var showChangeEmail = false

private enum ProfileNav: Hashable { case language, timezone }
```

And wrap the `NavigationStack` opener with the path:

```swift
NavigationStack(path: $path) { ... }
```

- [ ] **Step 3: Build + smoke**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -10
xcrun simctl io booted screenshot /tmp/myprofile-pass2.png 2>/dev/null || true
```

Manual smoke checklist (in simulator):

  1. Open Profile tab → see new `IDENTIDAD` + `PREFERENCIAS` sections.
  2. Tap "Idioma" → LanguagePickerView opens. Pick "English (US)". Pop back. Verify `Idioma` row shows "English (US)" and at least one system label (e.g., date in another view) re-renders in the new locale.
  3. Tap "Zona horaria" → search "Tokyo" → tap. Verify the trailing label updates.
  4. Tap "Teléfono" → ChangePhoneFlow opens. Cancel out (don't actually change phone unless intentional).
  5. Tap "Correo" → ChangeEmailFlow opens. Cancel out.

- [ ] **Step 4: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Views/MyProfileView.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/ProfileTab.swift
git commit -m "$(cat <<'EOF'
feat(profile): IDENTIDAD + PREFERENCIAS sections in MyProfileView

Wires phone/email change flows and language/timezone pickers into the
Profile tab. Trailing labels show current values from
profiles.{phone,locale,timezone} + auth.users.email. Identity layer
now has full FE surface for everything the BE already exposes.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

- [ ] **Step 5: Tag the Pass 2 milestone**

```bash
git tag -a level0-pass2-complete -m "Level 0 redesign — Pass 2 (profile field wire-up) complete"
```

---

## Done When

- All 10 tasks committed.
- `MyProfileView` has 5 sections: Hero, TU ACTIVIDAD, IDENTIDAD, PREFERENCIAS, AJUSTES + Apariencia inline + signout.
- No `SettingsSheet`, no `SettingsTabView`, no `Settings/` directory.
- `ProfileCoordinator` no longer references `Fine` or `FineRepository`.
- `xcodebuild build` succeeds with no warnings.
- Manual smoke verifies: language change, timezone change, phone/email flows open, signout works, appearance picker still toggles theme.
- Two milestone tags exist: `level0-pass1-complete`, `level0-pass2-complete`.

---

## Out of Scope (left for next plan)

- Pass 3 (multi-device + notification token revocation)
- Pass 4 (cross-group personal timeline + new `my_activity_v1` view)
- Pass 5 (`identity_atoms` exposed as Account history)
- Pass 6 (GDPR export + delete)
- Notification preferences per-tipo (requires new BE table)
- Linked identities management (Apple/Google linking)
