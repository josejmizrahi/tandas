# Level 1 Group — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5-sheet sprawl for Group with a single `GroupHomeView`, then wire-up every group-level mutation the BE already exposes (rename, currency, timezone, all 5 modules, regenerate invite code, change avatar).

**Architecture:** Two sequential passes. Pass 1 is a pure structural refactor (no BE) — create `GroupHomeView` + coordinator, move 2 governance subscreens, delete `GroupInfoSheet` + `GroupSettingsSheet`, retarget the header tap. Pass 2 extends `GroupsRepository` (only `GroupConfigPatch` needs new fields — most repo methods already exist) and adds 5 new subscreens.

**Tech Stack:** SwiftUI iOS 26+, Swift 6 strict concurrency, `@Observable` view models, supabase-swift 2.20+, Lefthook codegen.

**Source spec:** `docs/superpowers/specs/2026-05-15-level-1-group-redesign.md` (Pass 1 + Pass 2 sections).

---

## File Structure

### Pass 1 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/GroupHomeCoordinator.swift` | **Create** | New @Observable coordinator (~120 L) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift` | **Create** | Hero + 3 sections (Configuración, Comunidad, Avanzado). ~280 L. |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GovernanceView.swift` | **Move** | From `Features/Groups/Settings/GovernanceSettingsView.swift` (rename + relocate) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/RulePresetsView.swift` | **Move** | From `Features/Groups/Settings/GroupRulesSettingsView.swift` (rename + relocate) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Switcher/GroupInfoSheet.swift` | **DELETE** (640 L) | Content absorbed into `GroupHomeView` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/GroupSettingsSheet.swift` | **DELETE** (240 L) | Content absorbed into `GroupHomeView` (modules section + vocabulary subscreen) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/` (the directory) | **DELETE** | Becomes empty after the moves and the delete above |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift` | **Modify** | Add `case groupHome` to `SheetRoute` enum |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` | **Modify** | Add handler block for `.groupHome` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift` | **Modify** | Add `openGroupHome()` method |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/HomeTab.swift` | **Modify** | `onSwitchGroup: { router.openGroupSwitcher() }` becomes `onSwitchGroup: { router.openGroupHome() }`. The switcher moves to long-press in Pass 6 (separate plan); for Pass 1 the lift is just retargeting tap. |
| Any other call site of `router.openGroupSwitcher()` | **Modify** | Audit with grep; same retarget |

### Pass 2 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupsRepository.swift` | **Modify** | Add `name` + `description` to `GroupConfigPatch`. The `updateConfig` Live impl already does PostgREST update — extend it to include name/description if present in patch. |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/EditGroupIdentitySheet.swift` | **Create** | Bottom sheet medium-detent: rename + description + avatar picker (~200 L) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/ModulesPickerView.swift` | **Create** | List 5 modules from `ModuleRegistry.v1Fallback`. Toggle → `setModule` RPC. (~180 L) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GroupCurrencyPickerView.swift` | **Create** | 9 currency options. Tap → `updateConfig(patch: .init(currency:))`. (~120 L) |
| `ios/Packages/RuulUI/Sources/RuulUI/Patterns/TimezonePicker.swift` | **Create** | Refactored shared timezone picker (extracted from Nivel 0's `TimezonePickerView`). Takes `current: String`, `onSelect: (String) -> Void` callback. (~120 L) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/TimezonePickerView.swift` | **Modify** | Becomes thin wrapper that uses the shared `RuulUI.TimezonePicker` + writes `profileRepo.updateTimezone`. (~50 L). |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GroupTimezonePickerView.swift` | **Create** | Mirror that uses `RuulUI.TimezonePicker` + writes `groupsRepo.updateConfig(patch: .init(timezone:))`. (~50 L) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/RegenerateInviteCodeSheet.swift` | **Create** | Confirmation + new code reveal with copy/share. (~150 L) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift` | **Modify** | Add 5 navRows in Configuración + Avanzado sections. Add 4 init params for the new callbacks (or inline NavigationPath / sheet state). |

### Notes on testing

Same as Nivel 0: **no SPM test targets** in `RuulCore` / `RuulFeatures`. Verification = `xcodebuild build` + manual smoke. Add inline `#Preview` blocks to new views as a lightweight verification artifact. Do **not** create test directories.

### Notes on AppState API

- `app.groups: [Group]` — list of user's groups
- `app.activeGroup: Group?` — current group (computed from `activeGroupId`)
- `app.activeGroupId: UUID?` — persisted in UserDefaults
- `app.groupsRepo: any GroupsRepository` — verify exact name with `grep -n "groupsRepo" ios/Packages/RuulCore/Sources/RuulCore/AppState.swift` before writing repo calls
- `app.refreshProfileAndGroups() async` — reloads both profile and groups list

---

## Pass 1 — Structural separation (Tasks 1-6)

### Task 1: Create `GroupHomeCoordinator`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/GroupHomeCoordinator.swift`

**Why:** Centralize loading of `Group` + `[GroupModule]` (active modules resolved against `ModuleRegistry`) + member count, into one `@Observable` view model.

- [ ] **Step 1: Create the file**

Write:

```swift
import Foundation
import Observation
import OSLog
import RuulCore

@Observable
@MainActor
public final class GroupHomeCoordinator {
    public let groupId: UUID
    private let groupsRepo: any GroupsRepository
    private let moduleRegistry: ModuleRegistry
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.home")

    public var group: Group?
    public var memberCount: Int = 0
    public var activeModules: [GroupModule] = []
    public var isLoading: Bool = false
    public var error: CoordinatorError?

    public init(
        groupId: UUID,
        groupsRepo: any GroupsRepository,
        moduleRegistry: ModuleRegistry = .v1Fallback
    ) {
        self.groupId = groupId
        self.groupsRepo = groupsRepo
        self.moduleRegistry = moduleRegistry
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let detailTask = groupsRepo.get(groupId)
            async let membersTask = groupsRepo.members(of: groupId)
            let (detail, members) = try await (detailTask, membersTask)
            self.group = detail.group
            self.memberCount = members.count
            self.activeModules = resolveModules(slugs: detail.group.activeModules ?? [])
        } catch {
            log.warning("group home refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar el grupo")
        }
    }

    public func clearError() { error = nil }

    private func resolveModules(slugs: [String]) -> [GroupModule] {
        slugs.compactMap { slug in moduleRegistry.modules.first(where: { $0.id == slug }) }
    }
}
```

NOTE: confirm `GroupDetail.group: Group` exists (via `grep -n "struct GroupDetail" ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupsRepository.swift`). If the property is named differently, adapt the `detail.group` access. Also confirm `ModuleRegistry.modules` is the public collection (vs `.all` or `.allModules`); adjust if needed.

- [ ] **Step 2: Build**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/GroupHomeCoordinator.swift && \
git commit -m "$(cat <<'EOF'
feat(group): GroupHomeCoordinator — Nivel 1 scaffold

Loads Group + memberCount + resolved activeModules in one shot.
Replaces the per-sheet ad-hoc loading scattered across GroupInfoSheet
and GroupSettingsSheet.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 2: Create `GroupHomeView` (Pass 1 minimal scaffold)

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift`

**Why:** A single home for the group with all the sections from the doomed sheets + entry points to subscreens. Pass 1 wires only what existed before (members nav, governance link, leave); Pass 2 adds the rest.

- [ ] **Step 1: Create the file**

Write:

```swift
import SwiftUI
import RuulUI
import RuulCore

/// Nivel 1 home — the group as a persistent social domain.
/// Layout:
///   Hero (avatar + name + invite code + member count)
///   CONFIGURACIÓN (vocabulary + governance link in Pass 1; Pass 2 adds the rest)
///   COMUNIDAD (members + group activity in Pass 3)
///   AVANZADO (leave; Pass 2 adds rotate code; Pass 4 adds archive)
@MainActor
public struct GroupHomeView: View {
    @State var coordinator: GroupHomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let onOpenMembers: () -> Void
    public let onOpenGovernance: () -> Void
    public let onOpenRulePresets: () -> Void
    public let onLeaveGroup: () -> Void
    public let onShareInvite: () -> Void

    public init(
        coordinator: GroupHomeCoordinator,
        onOpenMembers: @escaping () -> Void,
        onOpenGovernance: @escaping () -> Void,
        onOpenRulePresets: @escaping () -> Void,
        onLeaveGroup: @escaping () -> Void,
        onShareInvite: @escaping () -> Void
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onOpenMembers = onOpenMembers
        self.onOpenGovernance = onOpenGovernance
        self.onOpenRulePresets = onOpenRulePresets
        self.onLeaveGroup = onLeaveGroup
        self.onShareInvite = onShareInvite
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.group == nil {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(RuulSpacing.lg)
                } else if coordinator.group == nil && coordinator.isLoading {
                    RuulLoadingState()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                            hero
                            configurationSection
                            communitySection
                            advancedSection
                        }
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.xs)
                        .padding(.bottom, RuulSpacing.s12)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await coordinator.refresh() }
                }
            }
        }
        .task { await coordinator.refresh() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            HStack(spacing: RuulSpacing.md) {
                RuulAvatar(
                    name: coordinator.group?.name ?? "?",
                    imageURL: coordinator.group?.avatarUrl.flatMap(URL.init(string:)),
                    size: .large
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.group?.name ?? "—")
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(2)
                    Text(memberLabel)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer(minLength: 0)
            }

            if let code = coordinator.group?.inviteCode {
                Button(action: onShareInvite) {
                    HStack(spacing: RuulSpacing.xs) {
                        Image(systemName: "link")
                            .ruulTextStyle(RuulTypography.subheadMedium)
                            .accessibilityHidden(true)
                        Text(code)
                            .ruulTextStyle(RuulTypography.bodyMonospaced)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                        Text("Compartir")
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulAccent)
                    }
                    .padding(RuulSpacing.md)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.medium)
                            .stroke(Color.ruulSeparator, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, RuulSpacing.md)
    }

    private var memberLabel: String {
        switch coordinator.memberCount {
        case 0: "Sin miembros"
        case 1: "1 miembro"
        default: "\(coordinator.memberCount) miembros"
        }
    }

    private var configurationSection: some View {
        sectionContainer(title: "CONFIGURACIÓN") {
            navRow(icon: "scale.3d", label: "Reglas del grupo", action: onOpenGovernance)
            divider
            navRow(icon: "list.bullet.clipboard", label: "Presets de reglas", action: onOpenRulePresets)
        }
    }

    private var communitySection: some View {
        sectionContainer(title: "COMUNIDAD") {
            navRow(
                icon: "person.2",
                label: "Miembros",
                trailing: { trailingValue("\(coordinator.memberCount)") },
                action: onOpenMembers
            )
        }
    }

    private var advancedSection: some View {
        sectionContainer(title: "AVANZADO") {
            navRow(
                icon: "rectangle.portrait.and.arrow.right",
                label: "Salir del grupo",
                action: onLeaveGroup,
                destructive: true
            )
        }
    }

    // MARK: Reusable

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, 56)
    }

    private func trailingValue(_ s: String) -> some View {
        Text(s)
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func navRow(
        icon: String,
        label: String,
        trailing: () -> some View = { EmptyView() },
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
}
```

NOTE: this references `RuulTypography.bodyMonospaced` — confirm it exists with `grep -n "bodyMonospaced\|monospaced" ios/Packages/RuulUI/Sources/RuulUI/Tokens/Typography.swift`. If absent, swap for `RuulTypography.body` + `.monospaced()` Swift modifier.

- [ ] **Step 2: Build**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift && \
git commit -m "$(cat <<'EOF'
feat(group): GroupHomeView (Pass 1 scaffold)

Hero (avatar + name + invite code + member count) + 3 sections
(Configuración, Comunidad, Avanzado). Pass 2 will add identity edit,
modules picker, currency/timezone, and code rotation rows. Subscreens
are still hosted by the legacy sheets — wiring happens in Task 5.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 3: Add `.groupHome` shell route

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift`

**Why:** Wire `GroupHomeView` into the shell as a full-screen cover route so any view can present it via `router.openGroupHome()`.

**Modal pattern note:** As of commit `7307480` (2026-05-15), every modal in the app uses `.fullScreenCover(...)`, not `.sheet(...)` — explicit founder directive ("todo debe ser full screen no sheet me equivoqué"). All sheet code in this plan uses `.fullScreenCover`. `.ruulSheetChrome(detents:)` is a silent no-op inside fullScreenCover so it can stay where present.

- [ ] **Step 1: Add route case**

Open `RootShellState.swift`. Find the `SheetRoute` enum (around line 84-110). Add a new case after `case groupSwitcher`:

```swift
    case groupHome              // GroupHomeView (Nivel 1 group dashboard)
```

- [ ] **Step 2: Add sheet handler**

Open `RootShellSheets.swift`. Find a similar handler block (e.g., the `.editProfile` sheet around line 147). Add a new block, modeled on it:

```swift
            // MARK: Group home sheet
            .fullScreenCover(isPresented: boolBinding(for: .groupHome)) {
                if let activeGroup = app.activeGroup {
                    let coord = GroupHomeCoordinator(
                        groupId: activeGroup.id,
                        groupsRepo: app.groupsRepo
                    )
                    NavigationStack {
                        GroupHomeView(
                            coordinator: coord,
                            onOpenMembers: { router.openMembers() },
                            onOpenGovernance: { router.present(.groupRulesSettings) },
                            onOpenRulePresets: { router.present(.groupRulesSettings) },
                            onLeaveGroup: {
                                Task {
                                    try? await app.groupsRepo.leave(activeGroup.id)
                                    await app.refreshProfileAndGroups()
                                    router.dismissTopSheet()
                                }
                            },
                            onShareInvite: {
                                // Reuse the invite-share route already in the shell.
                                router.present(.inviteShare)
                            }
                        )
                        .environment(app)
                    }
                    .ruulSheetChrome(detents: [.large])
                }
            }
```

The exact name of `router.dismissTopSheet()` may differ — check `grep -n "func dismiss\|func clearSheet\|func close" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift` and adapt. If a "dismiss top sheet" method doesn't exist, use a closure that flips the `boolBinding` to `false`.

- [ ] **Step 3: Add router method**

Open `RootRouter.swift`. Find a similar method (e.g., `openSanciones()` or `openMembers()`). Add:

```swift
    public func openGroupHome() {
        present(.groupHome)
    }
```

The `present(_:)` helper is the canonical way; copy whatever the neighboring methods do.

- [ ] **Step 4: Build**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift && \
git commit -m "$(cat <<'EOF'
feat(shell): groupHome sheet route + router method

Adds .groupHome to SheetRoute and openGroupHome() to RootRouter.
GroupHomeView is now reachable; HomeTab will retarget the group-switcher
chrome tap in the next task.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 4: Move `GovernanceSettingsView` + `GroupRulesSettingsView` to `Features/Group/Subscreens/`

**Files:**
- Move: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/GovernanceSettingsView.swift` → `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GovernanceView.swift`
- Move: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/GroupRulesSettingsView.swift` → `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/RulePresetsView.swift`

**Why:** Centralize all Group-Nivel-1 surfaces under one folder. The 2 governance views are conceptually subscreens of `GroupHomeView`.

- [ ] **Step 1: Move + rename file 1**

```bash
mkdir -p ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/GovernanceSettingsView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GovernanceView.swift
```

Open the moved file and:
- Change the `public struct GovernanceSettingsView: View` declaration to `public struct GovernanceView: View`.
- Update any `GovernanceSettingsView.*` references inside the same file (init, previews) to `GovernanceView`.
- Leave external references for Step 4.

- [ ] **Step 2: Move + rename file 2**

```bash
git mv ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/GroupRulesSettingsView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/RulePresetsView.swift
```

Same edit: rename type from `GroupRulesSettingsView` to `RulePresetsView` inside.

- [ ] **Step 3: Audit external callers**

```bash
grep -rn "GovernanceSettingsView\|GroupRulesSettingsView" ios/Packages ios/Tandas --include='*.swift' | grep -v "\.build"
```

For each hit, replace the type name with the new one (`GovernanceSettingsView` → `GovernanceView`, `GroupRulesSettingsView` → `RulePresetsView`).

- [ ] **Step 4: Build**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add -A ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/ \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/ && \
# also stage any caller files modified in step 3
git add $(grep -rln "GovernanceView\|RulePresetsView" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell --include='*.swift' | grep -v "\.build") && \
git commit -m "$(cat <<'EOF'
refactor(group): move GovernanceSettingsView + GroupRulesSettingsView

Renamed → GovernanceView + RulePresetsView and relocated under
Features/Group/Subscreens/. Centralizes all Nivel 1 surfaces in one
folder. No behavior change.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 5: Delete `GroupInfoSheet` + `GroupSettingsSheet` and retarget header tap

**Files:**
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Switcher/GroupInfoSheet.swift` (640 L)
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/GroupSettingsSheet.swift` (240 L)
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/` (now-empty directory)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/HomeTab.swift` (the `onSwitchGroup:` callback)
- Audit: any other caller of `router.openGroupSwitcher()` or `GroupInfoSheet()` or `GroupSettingsSheet()`

**Why:** Both old sheets are now redundant — their content lives in `GroupHomeView` + the moved subscreens. The header tap on `RuulGroupSwitcher` should open the new home, not the old info sheet.

- [ ] **Step 1: Audit callers**

```bash
grep -rn "GroupInfoSheet\|GroupSettingsSheet\|openGroupSwitcher\b" ios/Packages ios/Tandas --include='*.swift' | grep -v "\.build"
```

Save the output. You'll edit each location.

- [ ] **Step 2: Retarget `HomeTab.swift` `onSwitchGroup`**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/HomeTab.swift`. The current call (around line 33) is:

```swift
onSwitchGroup: { router.openGroupSwitcher() }
```

Change to:

```swift
onSwitchGroup: { router.openGroupHome() }
```

The `onSwitchGroup` closure name is misleading after this change but renaming it across `HomeView.swift` is out of scope for this task. The semantic meaning ("tap the group chrome") is preserved.

- [ ] **Step 3: For every other `openGroupSwitcher()` caller**, also retarget to `openGroupHome()` UNLESS the call is inside `GroupSwitcherSheet` itself or in a "switch groups" context (e.g., a button labeled "Cambiar grupo"). Use judgment per call site.

If unsure about a specific caller, leave it alone and report it as a concern in the commit message.

- [ ] **Step 4: Delete the two sheet files and the empty directory**

```bash
rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Switcher/GroupInfoSheet.swift
rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings/GroupSettingsSheet.swift
rmdir ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Settings 2>/dev/null
```

(The `rmdir` only succeeds if the dir is empty after Task 4 moved its other 2 files. If it errors with "directory not empty", inspect what's left and decide whether to keep or delete it.)

- [ ] **Step 5: Build to verify all callers cleaned**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```

Any error mentioning `GroupInfoSheet` or `GroupSettingsSheet` means a caller still references them — find and remove those references (typically replacing with `router.openGroupHome()` or removing the call entirely if it was a one-off button).

- [ ] **Step 6: Commit**

```bash
git add -A ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/ \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/Tabs/HomeTab.swift && \
# also stage any other caller you edited in step 3
git commit -m "$(cat <<'EOF'
refactor(group): kill GroupInfoSheet + GroupSettingsSheet

Header tap now opens GroupHomeView (router.openGroupHome) instead of
the old info sheet. The 880 lines across the two deleted files are
fully replaced by GroupHomeView + the moved governance subscreens.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 6: Pass 1 smoke verification

**Files:** None (verification only).

- [ ] **Step 1: Confirm clean build**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Manual simulator smoke (when convenient)**

Boot iOS 26 sim, sign in, verify:
1. Tap on the group name chrome in HomeView header → `GroupHomeView` opens (not the old info sheet)
2. The hero shows: avatar + name + member count + invite code with Compartir button
3. CONFIGURACIÓN section shows "Reglas del grupo" + "Presets de reglas" rows; tap each → opens existing governance views
4. COMUNIDAD section shows "Miembros (N)" → opens existing members sheet
5. AVANZADO section shows "Salir del grupo" — tap shows confirmation (or executes — verify behavior)
6. Long-press on the group chrome should still open `GroupSwitcherSheet` (existing behavior, nothing changed)

- [ ] **Step 3: Tag the milestone**

```bash
git tag -a level1-pass1-complete -m "Level 1 redesign — Pass 1 (GroupHomeView consolidation) complete"
```

---

## Pass 2 — Wire-up of group fields (Tasks 7-10)

### Task 7: Extend `GroupConfigPatch` + `EditGroupIdentitySheet`

**Files:**
- Modify: `ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupsRepository.swift` (add `name` + `description` to `GroupConfigPatch` + extend `updateConfig` Live impl)
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/EditGroupIdentitySheet.swift`

**Why:** `groups.name` and `groups.description` are mutable per RLS but `GroupConfigPatch` doesn't carry them. After this task, the `GroupHomeView` "Nombre y foto" row works.

- [ ] **Step 1: Extend `GroupConfigPatch`**

Open `ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupsRepository.swift`. Find the struct (line 68). Replace it with:

```swift
public struct GroupConfigPatch: Sendable, Equatable {
    public var name: String?
    public var description: String?
    public var initialEventVocabulary: String?
    public var coverImageName: String?
    public var currency: String?
    public var timezone: String?

    public init(
        name: String? = nil,
        description: String? = nil,
        initialEventVocabulary: String? = nil,
        coverImageName: String? = nil,
        currency: String? = nil,
        timezone: String? = nil
    ) {
        self.name = name
        self.description = description
        self.initialEventVocabulary = initialEventVocabulary
        self.coverImageName = coverImageName
        self.currency = currency
        self.timezone = timezone
    }
}
```

- [ ] **Step 2: Extend `LiveGroupsRepository.updateConfig`**

Find the Live impl (around line 571). It builds a PostgREST `update` with the patch fields. Add `name` and `description` to the dictionary it sends. The exact code depends on how the existing impl serializes — read it first. Pattern:

```swift
var payload: [String: AnyJSON] = [:]
if let name = patch.name { payload["name"] = .string(name) }
if let desc = patch.description { payload["description"] = .string(desc) }
// ... existing field handling ...
```

If the existing impl already iterates patch fields, just add the two new branches.

- [ ] **Step 3: Extend `MockGroupsRepository.updateConfig`**

Find the Mock impl (around line 184). Same idea — mutate the cached `_groups[i]` to set name/description if present.

- [ ] **Step 4: Create `EditGroupIdentitySheet.swift`**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/EditGroupIdentitySheet.swift`:

```swift
import SwiftUI
import PhotosUI
import RuulUI
import RuulCore

@MainActor
public struct EditGroupIdentitySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var saving = false
    @State private var error: String?

    public init(groupId: UUID) { self.groupId = groupId }

    private var current: Group? {
        app.groups.first(where: { $0.id == groupId })
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Nombre del grupo", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Descripción") {
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Foto") {
                    PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
                        HStack {
                            RuulAvatar(name: name.isEmpty ? "?" : name, imageURL: current?.avatarUrl.flatMap(URL.init(string:)), size: .medium)
                            Text(avatarItem == nil ? "Cambiar foto" : "Foto seleccionada")
                                .ruulTextStyle(RuulTypography.body)
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Color.ruulNegative) }
                }
            }
            .navigationTitle("Editar grupo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let g = current {
                    name = g.name
                    description = g.description ?? ""
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
            let patch = GroupConfigPatch(
                name: trimmedName != current?.name ? trimmedName : nil,
                description: trimmedDesc != (current?.description ?? "") ? trimmedDesc : nil
            )
            if patch.name != nil || patch.description != nil {
                _ = try await app.groupsRepo.updateConfig(groupId: groupId, patch: patch)
            }
            if let item = avatarItem,
               let data = try await item.loadTransferable(type: Data.self) {
                _ = try await app.groupsRepo.updateAvatar(
                    groupId: groupId,
                    data: data,
                    contentType: "image/jpeg"
                )
            }
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "No pudimos guardar los cambios."
        }
    }
}
```

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

Expected BUILD SUCCEEDED.

```bash
git add ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupsRepository.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/EditGroupIdentitySheet.swift && \
git commit -m "$(cat <<'EOF'
feat(group): name/description in GroupConfigPatch + EditGroupIdentitySheet

Extends GroupConfigPatch with name + description (already mutable per
RLS) and adds a sheet to rename + describe + change avatar in one place.
Wire-up into GroupHomeView lands in Task 10.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 8: `ModulesPickerView` (5 module toggles)

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/ModulesPickerView.swift`

**Why:** Today only `basic_fines` is toggleable in UI. The other 4 (`rotating_host`, `rsvp`, `check_in`, `appeal_voting`) are invisible despite `set_group_module` supporting them.

- [ ] **Step 1: Create the picker**

Write the file with this content:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct ModulesPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    @State private var saving: Set<String> = []
    @State private var error: String?

    public init(groupId: UUID) { self.groupId = groupId }

    private var current: Group? { app.groups.first(where: { $0.id == groupId }) }
    private var activeSlugs: Set<String> { Set(current?.activeModules ?? []) }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(ModuleRegistry.v1Fallback.modules, id: \.id) { module in
                    moduleRow(module)
                    if module.id != ModuleRegistry.v1Fallback.modules.last?.id {
                        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
            .padding(RuulSpacing.lg)

            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(.horizontal, RuulSpacing.lg)
            }
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .navigationTitle("Módulos")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func moduleRow(_ module: GroupModule) -> some View {
        let enabled = activeSlugs.contains(module.id)
        let isSaving = saving.contains(module.id)
        let conflicts = module.conflictsWith.filter(activeSlugs.contains)
        let unsatisfiedDeps = module.dependencies.filter { !activeSlugs.contains($0) }
        let blocked = !enabled && (!conflicts.isEmpty || !unsatisfiedDeps.isEmpty)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(module.description)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { newVal in Task { await toggle(module.id, newVal) } }
                ))
                .labelsHidden()
                .disabled(isSaving || blocked)
            }
            if blocked && !conflicts.isEmpty {
                Text("Conflictúa con: \(conflicts.joined(separator: ", "))")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulWarning)
            }
            if blocked && !unsatisfiedDeps.isEmpty {
                Text("Requiere: \(unsatisfiedDeps.joined(separator: ", "))")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .padding(RuulSpacing.md)
    }

    private func toggle(_ slug: String, _ newValue: Bool) async {
        saving.insert(slug)
        defer { saving.remove(slug) }
        do {
            _ = try await app.groupsRepo.setModule(groupId: groupId, slug: slug, enabled: newValue)
            await app.refreshProfileAndGroups()
        } catch {
            self.error = "No pudimos cambiar el módulo."
        }
    }
}
```

NOTE: `ModuleRegistry.v1Fallback.modules` and `GroupModule.conflictsWith` / `.dependencies` / `.description` field names — verify with `grep -n "public " ios/Packages/RuulCore/Sources/RuulCore/PlatformModules/*.swift`. Adjust if names differ slightly.

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/ModulesPickerView.swift && \
git commit -m "$(cat <<'EOF'
feat(group): ModulesPickerView (all 5 module toggles)

Lists every module from ModuleRegistry.v1Fallback. Toggle calls
setModule RPC. Conflicts and unsatisfied dependencies are shown as
inline blockers (toggle disabled until they resolve).

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 9: Currency picker + shared TimezonePicker refactor

**Files:**
- Create: `ios/Packages/RuulUI/Sources/RuulUI/Patterns/TimezonePicker.swift` (shared primitive)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/TimezonePickerView.swift` (becomes thin wrapper)
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GroupTimezonePickerView.swift`
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GroupCurrencyPickerView.swift`

**Why:** DRY — Nivel 0 already has a timezone picker; lift it into `RuulUI` so both Nivel 0 and Nivel 1 share one. Currency picker is new.

- [ ] **Step 1: Lift the timezone picker into `RuulUI`**

Write `ios/Packages/RuulUI/Sources/RuulUI/Patterns/TimezonePicker.swift`:

```swift
import SwiftUI

/// Reusable filterable IANA timezone picker.
/// The owner provides `current` and reacts to `onSelect`. Picker handles
/// search + offset display; persistence is the caller's responsibility.
public struct TimezonePicker: View {
    public let current: String
    public let onSelect: (String) async -> Void

    @State private var query = ""
    @State private var saving = false

    public init(current: String, onSelect: @escaping (String) async -> Void) {
        self.current = current
        self.onSelect = onSelect
    }

    private var allZones: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }
    private var filteredZones: [String] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return allZones }
        let q = query.lowercased()
        return allZones.filter { $0.lowercased().contains(q) }
    }

    public var body: some View {
        List {
            ForEach(filteredZones, id: \.self) { tz in
                Button {
                    Task {
                        saving = true
                        await onSelect(tz)
                        saving = false
                    }
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
    }

    private func offsetLabel(for tz: String) -> String {
        guard let zone = TimeZone(identifier: tz) else { return "" }
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs((seconds % 3600) / 60)
        let sign = seconds >= 0 ? "+" : "-"
        return String(format: "GMT%@%02d:%02d", sign, abs(hours), minutes)
    }
}
```

- [ ] **Step 2: Slim down the Nivel 0 view**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/TimezonePickerView.swift`. Replace its body with a thin wrapper:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct TimezonePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        TimezonePicker(
            current: app.profile?.timezone ?? TimeZone.current.identifier,
            onSelect: { tz in
                guard tz != (app.profile?.timezone ?? "") else { dismiss(); return }
                do {
                    try await app.profileRepo.updateTimezone(tz)
                    await app.refreshProfileAndGroups()
                    dismiss()
                } catch {
                    // Picker shows nothing; consider a Toast in a follow-up.
                }
            }
        )
        .navigationTitle("Zona horaria")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] **Step 3: Create the Group variant**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GroupTimezonePickerView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct GroupTimezonePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    public init(groupId: UUID) { self.groupId = groupId }

    private var current: String {
        app.groups.first(where: { $0.id == groupId })?.timezone ?? TimeZone.current.identifier
    }

    public var body: some View {
        TimezonePicker(
            current: current,
            onSelect: { tz in
                guard tz != current else { dismiss(); return }
                do {
                    _ = try await app.groupsRepo.updateConfig(
                        groupId: groupId,
                        patch: GroupConfigPatch(timezone: tz)
                    )
                    await app.refreshProfileAndGroups()
                    dismiss()
                } catch { /* see TODO note in TimezonePickerView */ }
            }
        )
        .navigationTitle("Zona del grupo")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] **Step 4: Create the currency picker**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GroupCurrencyPickerView.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct GroupCurrencyPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    @State private var saving = false
    @State private var error: String?

    public init(groupId: UUID) { self.groupId = groupId }

    /// Beta-1 supported currencies.
    public static let supported: [(code: String, label: String, symbol: String)] = [
        ("MXN", "Peso mexicano",       "$"),
        ("USD", "Dólar estadounidense", "US$"),
        ("EUR", "Euro",                "€"),
        ("GBP", "Libra esterlina",     "£"),
        ("ARS", "Peso argentino",      "AR$"),
        ("BRL", "Real brasileño",      "R$"),
        ("CLP", "Peso chileno",        "CL$"),
        ("COP", "Peso colombiano",     "CO$"),
        ("PEN", "Sol peruano",         "S/")
    ]

    private var current: String {
        app.groups.first(where: { $0.id == groupId })?.currency ?? "MXN"
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Self.supported, id: \.code) { entry in
                    Button { Task { await select(entry.code) } } label: {
                        HStack {
                            Text(entry.symbol)
                                .ruulTextStyle(RuulTypography.bodyMonospaced)
                                .frame(width: 44, alignment: .leading)
                                .foregroundStyle(Color.ruulTextSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label)
                                    .ruulTextStyle(RuulTypography.body)
                                    .foregroundStyle(Color.ruulTextPrimary)
                                Text(entry.code)
                                    .ruulTextStyle(RuulTypography.caption)
                                    .foregroundStyle(Color.ruulTextSecondary)
                            }
                            Spacer()
                            if entry.code == current {
                                Image(systemName: "checkmark")
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
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
            .padding(RuulSpacing.lg)
            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
            }
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .navigationTitle("Moneda del grupo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ code: String) async {
        guard code != current else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            _ = try await app.groupsRepo.updateConfig(
                groupId: groupId,
                patch: GroupConfigPatch(currency: code)
            )
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "No pudimos cambiar la moneda."
        }
    }
}
```

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulUI/Sources/RuulUI/Patterns/TimezonePicker.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/Subscreens/TimezonePickerView.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GroupTimezonePickerView.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GroupCurrencyPickerView.swift && \
git commit -m "$(cat <<'EOF'
feat(group): currency + group timezone + shared TimezonePicker primitive

Lifts the IANA picker into RuulUI/Patterns/TimezonePicker so Nivel 0 and
Nivel 1 share one. New GroupCurrencyPickerView lists 9 LATAM/global
currencies.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 10: `RegenerateInviteCodeSheet` + wire all subscreens into `GroupHomeView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/RegenerateInviteCodeSheet.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift` (add 5 navRows + 5 callbacks)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` (extend the `.groupHome` handler with NavigationPath + sheets)

**Why:** Final wire-up. After this task, the user can rename, change avatar, change currency, change timezone, toggle modules, and rotate the invite code from one place.

- [ ] **Step 1: Create the rotate-code sheet**

Write `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/RegenerateInviteCodeSheet.swift`:

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct RegenerateInviteCodeSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    @State private var step: Step = .confirm
    @State private var newCode: String?
    @State private var rotating = false
    @State private var error: String?

    private enum Step { case confirm, success }

    public init(groupId: UUID) { self.groupId = groupId }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                switch step {
                case .confirm:
                    confirmStep
                case .success:
                    successStep
                }
            }
            .padding(RuulSpacing.lg)
            .navigationTitle(step == .confirm ? "Rotar código" : "Nuevo código")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Esto invalidará el código actual. Los nuevos miembros usarán el nuevo código para unirse.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
            }
            Spacer()
            Button { Task { await rotate() } } label: {
                if rotating {
                    ProgressView()
                } else {
                    Text("Rotar código")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(rotating)
        }
    }

    private var successStep: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Tu nuevo código:")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            if let code = newCode {
                Text(code)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .padding(RuulSpacing.md)
                    .frame(maxWidth: .infinity)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                ShareLink(item: "Únete a mi grupo: \(code)") {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button("Listo") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func rotate() async {
        rotating = true
        error = nil
        defer { rotating = false }
        do {
            let code = try await app.groupsRepo.regenerateInviteCode(groupId: groupId)
            await app.refreshProfileAndGroups()
            self.newCode = code
            self.step = .success
        } catch {
            self.error = "No pudimos rotar el código. Verifica que tienes permisos."
        }
    }
}
```

- [ ] **Step 2: Extend `GroupHomeView` with 5 new init params + nav rows**

Open `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift`. Add after the existing init params:

```swift
public var onEditIdentity: (() -> Void)?
public var onPickModules: (() -> Void)?
public var onPickCurrency: (() -> Void)?
public var onPickTimezone: (() -> Void)?
public var onRotateCode: (() -> Void)?
```

Update the `init` to accept them with `nil` defaults (mirroring the pattern from Nivel 0 Pass 2 Task 10).

Replace the `configurationSection` with:

```swift
private var configurationSection: some View {
    sectionContainer(title: "CONFIGURACIÓN") {
        navRow(icon: "pencil", label: "Nombre y foto", action: { onEditIdentity?() })
        divider
        navRow(
            icon: "dollarsign.circle",
            label: "Moneda",
            trailing: { trailingValue(coordinator.group?.currency ?? "—") },
            action: { onPickCurrency?() }
        )
        divider
        navRow(
            icon: "clock",
            label: "Zona horaria",
            trailing: { trailingValue(coordinator.group?.timezone ?? "—") },
            action: { onPickTimezone?() }
        )
        divider
        navRow(
            icon: "puzzlepiece",
            label: "Módulos",
            trailing: { trailingValue("\(coordinator.activeModules.count) activos") },
            action: { onPickModules?() }
        )
        divider
        navRow(icon: "scale.3d", label: "Reglas del grupo", action: onOpenGovernance)
        divider
        navRow(icon: "list.bullet.clipboard", label: "Presets de reglas", action: onOpenRulePresets)
    }
}
```

Add to `advancedSection` BEFORE the existing `Salir del grupo`:

```swift
navRow(icon: "arrow.triangle.2.circlepath", label: "Rotar código de invitación", action: { onRotateCode?() })
divider
```

- [ ] **Step 3: Wire the new callbacks in `RootShellSheets.swift`**

Open the `.groupHome` sheet block created in Task 3. Replace the inner `GroupHomeView(...)` call so it has its own `NavigationPath` and presents the new subscreens. The pattern mirrors `ProfileTab` from Nivel 0 Task 10:

```swift
            .fullScreenCover(isPresented: boolBinding(for: .groupHome)) {
                if let activeGroup = app.activeGroup {
                    GroupHomeSheetContent(group: activeGroup, app: app, router: router)
                }
            }
```

And add a private SwiftUI view at the bottom of `RootShellSheets.swift`:

```swift
@MainActor
private struct GroupHomeSheetContent: View {
    let group: RuulCore.Group
    let app: AppState
    let router: RootRouter

    @State private var path = NavigationPath()
    @State private var showEditIdentity = false
    @State private var showRotateCode = false

    private enum GroupNav: Hashable { case modules, currency, timezone, governance, rulePresets }

    var body: some View {
        let coord = GroupHomeCoordinator(groupId: group.id, groupsRepo: app.groupsRepo)
        NavigationStack(path: $path) {
            GroupHomeView(
                coordinator: coord,
                onOpenMembers: { router.openMembers() },
                onOpenGovernance: { path.append(GroupNav.governance) },
                onOpenRulePresets: { path.append(GroupNav.rulePresets) },
                onLeaveGroup: {
                    Task {
                        try? await app.groupsRepo.leave(group.id)
                        await app.refreshProfileAndGroups()
                    }
                },
                onShareInvite: { router.present(.inviteShare) },
                onEditIdentity: { showEditIdentity = true },
                onPickModules: { path.append(GroupNav.modules) },
                onPickCurrency: { path.append(GroupNav.currency) },
                onPickTimezone: { path.append(GroupNav.timezone) },
                onRotateCode: { showRotateCode = true }
            )
            .navigationDestination(for: GroupNav.self) { dest in
                switch dest {
                case .modules:      ModulesPickerView(groupId: group.id)
                case .currency:     GroupCurrencyPickerView(groupId: group.id)
                case .timezone:     GroupTimezonePickerView(groupId: group.id)
                case .governance:   GovernanceView()  // confirm init signature; pass groupId if required
                case .rulePresets:  RulePresetsView() // same
                }
            }
            .fullScreenCover(isPresented: $showEditIdentity) {
                EditGroupIdentitySheet(groupId: group.id)
            }
            .fullScreenCover(isPresented: $showRotateCode) {
                RegenerateInviteCodeSheet(groupId: group.id)
            }
        }
        .environment(app)
        .ruulSheetChrome(detents: [.large])
    }
}
```

The `GovernanceView()` and `RulePresetsView()` inits depend on what the moved files expose — confirm with `grep -n "public init" ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/GovernanceView.swift ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/RulePresetsView.swift`. Adjust the calls accordingly.

- [ ] **Step 4: Build + smoke + commit + tag**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
```

Commit:

```bash
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Subscreens/RegenerateInviteCodeSheet.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift && \
git commit -m "$(cat <<'EOF'
feat(group): wire identity/modules/currency/timezone/code rotation into GroupHomeView

Final Pass 2 wiring. The GroupHomeView sheet now hosts a full nav
hierarchy: 5 subscreens via NavigationPath + 2 modals (EditGroupIdentitySheet,
RegenerateInviteCodeSheet). Every group-level mutation the BE already
exposes is now reachable from the UI.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"

git tag -a level1-pass2-complete -m "Level 1 redesign — Pass 2 (group field wire-up) complete"
```

---

## Done When

- All 10 tasks committed.
- Tap-en-nombre-del-grupo en HomeView → opens `GroupHomeView`.
- `GroupHomeView` has hero + 3 sections (Configuración, Comunidad, Avanzado).
- 5 subscreens reachable from `GroupHomeView`: ModulesPickerView, GroupCurrencyPickerView, GroupTimezonePickerView, GovernanceView, RulePresetsView.
- 2 modals reachable: EditGroupIdentitySheet, RegenerateInviteCodeSheet.
- `GroupInfoSheet` and `GroupSettingsSheet` files no longer exist.
- `xcodebuild build` passes with no warnings.
- Two tags exist: `level1-pass1-complete`, `level1-pass2-complete`.

---

## Out of Scope (next plans)

- Pass 3 (group activity feed from `system_events`)
- Pass 4 (archive + restore "papelera")
- Pass 5 (custom governance builder — separate spec)
- Pass 6 (long-press for switcher chrome polish)
