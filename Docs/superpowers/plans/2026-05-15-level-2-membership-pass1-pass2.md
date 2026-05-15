# Level 2 Membership — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the conflated 578-line `EditMembersSheet` with two role-specific surfaces (`MembersListView` for everyone, `MembersAdminView` for admins), then wire bulk-invite + self-leave from `GroupHomeView`.

**Architecture:** Two sequential passes. Pass 1 is a structural refactor + admin-gating (no BE). Pass 2 wires the post-onboarding invite flow and the missing self-leave confirmation — both use existing repo methods (`InviteRepository.createInvite`, `GroupsRepository.leave`).

**Tech Stack:** SwiftUI iOS 26+, Swift 6 strict concurrency, `@Observable` view models, supabase-swift 2.20+, Lefthook codegen.

**Source spec:** `docs/superpowers/specs/2026-05-15-level-2-membership-redesign.md` (Pass 1 + Pass 2 sections).

---

## File Structure

### Pass 1 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/MembersCoordinator.swift` | **Create** | New @Observable coordinator (~100 L). Loads `[MemberWithProfile]` + computes `isCurrentUserAdmin` flag |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersListView.swift` | **Create** | Read-only list for everyone (~180 L) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersAdminView.swift` | **Create** | Admin superset (~280 L). Extracts drag-reorder + kick + future invite affordances from EditMembersSheet |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Members/EditMembersSheet.swift` | **DELETE** (578 L) | Content split across the 2 new views |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift` | **Modify** | Rename `case members` → `case membersAdmin`; add `case membersList` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` | **Modify** | Replace the `.members` `.fullScreenCover` block with two new ones (.membersList + .membersAdmin) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift` | **Modify** | Rename `openMembers()` → `openMembersAdmin()`; add `openMembersList()` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift` | **Modify** | Replace single `onOpenMembers` callback with admin-aware split: list OR admin based on current user |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/GroupHomeCoordinator.swift` | **Modify** | Expose `isCurrentUserAdmin: Bool` derived from `members + session.user.id` |
| Any other `router.openMembers()` caller | **Modify** | Audit + retarget |

### Pass 2 — files touched

| File | Action | Notes |
|---|---|---|
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/InviteMembersFromGroupView.swift` | **Create** | Bulk invite reusing PendingInvite + `InviteRepository.createInvite` (~200 L). Share link + manual phone add + list pending |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/LeaveGroupConfirmationSheet.swift` | **Create** | 2-state sheet: confirm + execute; blocks if user is sole admin (~160 L) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift` | **Modify** | Wire `onLeaveGroup` to present confirmation; add "Invitar miembros" row to COMUNIDAD section (admin-only) |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersAdminView.swift` | **Modify** | Toolbar "+" button → presents `InviteMembersFromGroupView` |
| `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` | **Modify** | `GroupHomeSheetContent` adds `@State showInvite` + `@State showLeave` modals |

### Notes on testing

Same policy as L0/L1: **no SPM test targets**. DoD = `xcodebuild build` clean + manual smoke. No `Tests/` directories.

### Verified facts (do NOT re-verify in subagents — pass as context)

- `Member.isFounder: Bool` exists at `ios/Packages/RuulCore/Sources/RuulCore/Member.swift:98`. **In this codebase admin = founder** (per `CapabilityResolver+SecondaryActions.swift`). Use `member.isFounder` everywhere as the admin check.
- `MemberDetailView(memberWithProfile:group:isCurrentUser:)` exists; reuse it from both `MembersListView` and `MembersAdminView`.
- `app.policyRepo: any GroupPolicyRepository` (not `PolicyRepository`).
- `app.inviteRepo: any InviteRepository` — confirm with `grep -n "inviteRepo\b" ios/Packages/RuulCore/Sources/RuulCore/AppState.swift`. If property name differs, adapt.
- `app.groupsRepo.leave(_: UUID) async throws` — already exists (mig 00115).
- Modal policy: every modal is `.fullScreenCover`. `.ruulSheetChrome` API was removed.
- Token names: `RuulRadius.lg`/`.md`, `RuulTypography.mono` (NOT `.bodyMonospaced`).
- `RuulCore.Group` (NOT bare `Group` — SwiftUI conflict).

---

## Pass 1 — Structural separation (Tasks 1-5)

### Task 1: Create `MembersCoordinator`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/MembersCoordinator.swift`

**Why:** Both views (list + admin) need the same data — members with profiles + admin detection — so we centralize.

- [ ] **Step 1: Create the file**

Write:

```swift
import Foundation
import Observation
import OSLog
import RuulCore

@Observable
@MainActor
public final class MembersCoordinator {
    public let group: RuulCore.Group
    public let actorUserId: UUID
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "members")

    public var members: [MemberWithProfile] = []
    public var isLoading: Bool = false
    public var error: CoordinatorError?

    public init(
        group: RuulCore.Group,
        actorUserId: UUID,
        groupsRepo: any GroupsRepository
    ) {
        self.group = group
        self.actorUserId = actorUserId
        self.groupsRepo = groupsRepo
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            self.members = try await groupsRepo.membersWithProfiles(of: group.id)
        } catch {
            log.warning("members refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar los miembros")
        }
    }

    public func clearError() { error = nil }

    /// True when the calling user is a founder in this group (= admin).
    public var isCurrentUserAdmin: Bool {
        members.first(where: { $0.member.userId == actorUserId })?.member.isFounder ?? false
    }

    public func member(for userId: UUID) -> MemberWithProfile? {
        members.first(where: { $0.member.userId == userId })
    }

    public var activeMembers: [MemberWithProfile] {
        members.filter { $0.member.active }
    }
}
```

Verify `MemberWithProfile.member: Member` and `Member.userId: UUID` + `.active: Bool` by inspecting `ios/Packages/RuulCore/Sources/RuulCore/Member.swift`. Adjust property paths if any name differs.

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/MembersCoordinator.swift && \
git commit -m "$(cat <<'EOF'
feat(members): MembersCoordinator — Nivel 2 scaffold

@Observable coordinator that loads MemberWithProfile list and exposes
isCurrentUserAdmin (= founder per existing convention). Shared by the
two new role-specific views landing in the next tasks.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 2: Create `MembersListView` (read-only for everyone)

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersListView.swift`

**Why:** Non-admin members need a clean read-only list. Admin users will see the admin variant instead (gated by Task 5's wiring).

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct MembersListView: View {
    @State var coordinator: MembersCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: MembersCoordinator) {
        self._coordinator = State(initialValue: coordinator)
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.members.isEmpty {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(RuulSpacing.lg)
                } else if coordinator.isLoading && coordinator.members.isEmpty {
                    RuulLoadingState()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(coordinator.activeMembers) { row in
                                NavigationLink {
                                    MemberDetailView(
                                        memberWithProfile: row,
                                        group: coordinator.group,
                                        isCurrentUser: row.member.userId == coordinator.actorUserId
                                    )
                                } label: {
                                    memberRow(row)
                                }
                                .buttonStyle(.plain)
                                if row.id != coordinator.activeMembers.last?.id {
                                    Divider().background(Color.ruulSeparator).padding(.leading, 76)
                                }
                            }
                        }
                        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                        .padding(RuulSpacing.lg)
                    }
                    .refreshable { await coordinator.refresh() }
                }
            }
        }
        .navigationTitle("Miembros (\(coordinator.activeMembers.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cerrar") { dismiss() }
            }
        }
        .task { await coordinator.refresh() }
    }

    @ViewBuilder
    private func memberRow(_ row: MemberWithProfile) -> some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: row.displayName,
                imageURL: row.avatarURL,
                size: .medium
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: RuulSpacing.xxs) {
                    Text(row.displayName)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if row.member.userId == coordinator.actorUserId {
                        Text("· Tú")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Text(subtitleFor(row))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            if row.member.isFounder {
                Text("FUNDADOR")
                    .ruulTextStyle(RuulTypography.footnoteBold)
                    .foregroundStyle(Color.ruulAccent)
            }
            Image(systemName: "chevron.right")
                .ruulTextStyle(RuulTypography.captionBold)
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityHidden(true)
        }
        .padding(RuulSpacing.md)
        .contentShape(Rectangle())
    }

    private func subtitleFor(_ row: MemberWithProfile) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return "Se unió \(formatter.localizedString(for: row.member.joinedAt, relativeTo: .now))"
    }
}

extension MemberWithProfile: Identifiable {
    public var id: UUID { member.id }
}
```

NOTES:
- `MemberWithProfile.displayName: String` and `.avatarURL: URL?` — confirm signatures by reading the existing model. If accessor is `row.profile?.avatarUrl` instead, adapt.
- `RuulTypography.footnoteBold` may not exist — fallback to `.footnote` + Swift `.fontWeight(.bold)` if so.
- The `extension MemberWithProfile: Identifiable` block might already exist somewhere — `grep -rn "extension MemberWithProfile.*Identifiable" ios/Packages --include='*.swift'`. If yes, delete this block.

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersListView.swift && \
git commit -m "$(cat <<'EOF'
feat(members): MembersListView — read-only list for non-admins

Avatar + display name + relative joined date. Tap → MemberDetailView.
FUNDADOR badge shown inline. Replaces the lower half of EditMembersSheet
for non-admin users.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 3: Create `MembersAdminView` (admin superset)

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersAdminView.swift`

**Why:** Admin users need kick + reorder + future invite actions. This view absorbs all the admin-side affordances from `EditMembersSheet` while leaving the reading experience to `MembersListView`.

- [ ] **Step 1: Inspect the old sheet for behavior to preserve**

```bash
sed -n '1,100p' ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Members/EditMembersSheet.swift
```

Note especially:
- How drag-reorder works (uses `.onMove` with `setTurnOrder` RPC)
- How kick confirmation is presented
- How policy resolution determines `canRemove` vs `canPropose`

- [ ] **Step 2: Create the file**

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct MembersAdminView: View {
    @State var coordinator: MembersCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var memberToKick: MemberWithProfile?
    @State private var saving = false
    @State private var error: String?

    public var onInviteTap: (() -> Void)?

    public init(coordinator: MembersCoordinator, onInviteTap: (() -> Void)? = nil) {
        self._coordinator = State(initialValue: coordinator)
        self.onInviteTap = onInviteTap
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            content
        }
        .navigationTitle("Administrar miembros")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cerrar") { dismiss() }
            }
            if let onInviteTap {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onInviteTap) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Invitar miembros")
                }
            }
        }
        .alert("Echar a este miembro", isPresented: kickAlertBinding, presenting: memberToKick) { row in
            Button("Echar", role: .destructive) { Task { await kick(row) } }
            Button("Cancelar", role: .cancel) { memberToKick = nil }
        } message: { row in
            Text("\(row.displayName) perderá acceso al grupo.")
        }
        .task { await coordinator.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.isLoading && coordinator.members.isEmpty {
            RuulLoadingState()
        } else if let err = coordinator.error, coordinator.members.isEmpty {
            ErrorStateView(error: err, retry: { Task { await coordinator.refresh() } })
                .padding(RuulSpacing.lg)
        } else {
            List {
                ForEach(coordinator.activeMembers) { row in
                    NavigationLink {
                        MemberDetailView(
                            memberWithProfile: row,
                            group: coordinator.group,
                            isCurrentUser: row.member.userId == coordinator.actorUserId
                        )
                    } label: {
                        adminRow(row)
                    }
                    .swipeActions(edge: .trailing) {
                        if row.member.userId != coordinator.actorUserId {
                            Button(role: .destructive) {
                                memberToKick = row
                            } label: {
                                Label("Echar", systemImage: "trash")
                            }
                        }
                    }
                }
                .onMove(perform: moveMembers)
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .refreshable { await coordinator.refresh() }
        }
    }

    @ViewBuilder
    private func adminRow(_ row: MemberWithProfile) -> some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(name: row.displayName, imageURL: row.avatarURL, size: .medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(provenanceLabel(row.member))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            if row.member.isFounder {
                Text("FUNDADOR")
                    .ruulTextStyle(RuulTypography.footnoteBold)
                    .foregroundStyle(Color.ruulAccent)
            }
        }
        .padding(.vertical, RuulSpacing.xxs)
    }

    private func provenanceLabel(_ m: Member) -> String {
        switch m.joinedVia {
        case "founder_seed":  return "Fundador del grupo"
        case "invite_code":   return "Se unió por código"
        case "admin_add":     return "Agregado por admin"
        default:              return "Miembro"
        }
    }

    private var kickAlertBinding: Binding<Bool> {
        Binding(get: { memberToKick != nil }, set: { if !$0 { memberToKick = nil } })
    }

    private func kick(_ row: MemberWithProfile) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await app.groupsRepo.removeMember(
                groupId: coordinator.group.id,
                userId: row.member.userId,
                reason: nil
            )
            await coordinator.refresh()
            memberToKick = nil
        } catch {
            self.error = "No pudimos remover al miembro."
        }
    }

    private func moveMembers(from source: IndexSet, to destination: Int) {
        var ordered = coordinator.activeMembers
        ordered.move(fromOffsets: source, toOffset: destination)
        Task {
            do {
                try await app.groupsRepo.setTurnOrder(
                    groupId: coordinator.group.id,
                    userIds: ordered.map { $0.member.userId }
                )
                await coordinator.refresh()
            } catch {
                self.error = "No pudimos guardar el nuevo orden."
                await coordinator.refresh() // snap back
            }
        }
    }
}
```

NOTES:
- `Member.joinedVia: String?` — confirm. If absent (older schema), fall back to `"Miembro"`.
- `groupsRepo.removeMember` signature — confirm in `GroupsRepository.swift`. Adjust args if needed.
- `groupsRepo.setTurnOrder` already exists per the L1 audit.

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersAdminView.swift && \
git commit -m "$(cat <<'EOF'
feat(members): MembersAdminView — admin superset

Drag-reorder turn (.onMove + setTurnOrder), swipe-to-kick with
confirmation alert, joined_via provenance subtitle, optional invite
toolbar button. Replaces the admin half of EditMembersSheet.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 4: Update shell routes (`.members` → `.membersAdmin` + new `.membersList`)

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift` (line ~113)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` (the `.members` fullScreenCover block)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift` (line ~177)

**Why:** Two new routes wire the two new views into the shell.

- [ ] **Step 1: Rename + add route case**

Open `RootShellState.swift`. Find:

```swift
case members                // EditMembersSheet (group member management)
```

Replace with:

```swift
case membersList            // MembersListView (read-only, everyone)
case membersAdmin           // MembersAdminView (admin actions)
```

- [ ] **Step 2: Replace the sheet handler**

Open `RootShellSheets.swift`. Find the `.fullScreenCover(isPresented: boolBinding(for: .members))` block. Replace it with two new blocks:

```swift
            .fullScreenCover(isPresented: boolBinding(for: .membersList)) {
                if let activeGroup = app.activeGroup, let uid = app.session?.user.id {
                    NavigationStack {
                        MembersListView(coordinator: MembersCoordinator(
                            group: activeGroup,
                            actorUserId: uid,
                            groupsRepo: app.groupsRepo
                        ))
                        .environment(app)
                    }
                }
            }
            .fullScreenCover(isPresented: boolBinding(for: .membersAdmin)) {
                if let activeGroup = app.activeGroup, let uid = app.session?.user.id {
                    NavigationStack {
                        MembersAdminView(coordinator: MembersCoordinator(
                            group: activeGroup,
                            actorUserId: uid,
                            groupsRepo: app.groupsRepo
                        ))
                        .environment(app)
                    }
                }
            }
```

- [ ] **Step 3: Update router**

Open `RootRouter.swift`. Find `public func openMembers()` (line ~177). Rename to `openMembersAdmin()` and add a sibling `openMembersList()`:

```swift
    public func openMembersList() { present(.membersList) }
    public func openMembersAdmin() { present(.membersAdmin) }
```

- [ ] **Step 4: Find every `router.openMembers()` caller and retarget**

```bash
grep -rn "router\.openMembers()\|openMembers\b" ios/Packages ios/Tandas --include='*.swift' | grep -v "\.build"
```

For each hit, decide:
- If the caller is in `GroupHomeView` — leave it alone for now (Task 5 rewires it explicitly with admin detection).
- Anywhere else — for now, retarget to `openMembersAdmin()` as a conservative default. Task 5 may revise specific cases.

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellState.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootRouter.swift && \
git commit -m "$(cat <<'EOF'
feat(shell): split members route into list + admin

case members → case membersList + case membersAdmin. openMembers() →
openMembersList()/openMembersAdmin(). The two fullScreenCover handlers
embed the new MembersCoordinator + role-specific view. Wiring from
GroupHomeView lands in the next task.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 5: Wire from `GroupHomeView` + delete `EditMembersSheet`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/GroupHomeCoordinator.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` (`GroupHomeSheetContent`)
- Delete: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Members/EditMembersSheet.swift`

**Why:** The single `onOpenMembers` callback on `GroupHomeView` now routes to admin OR list based on `isCurrentUserAdmin`.

- [ ] **Step 1: Expose admin flag on coordinator**

Open `GroupHomeCoordinator.swift`. Add:

```swift
    /// True when the calling user is a founder in this group (= admin).
    /// Resolved lazily — requires `refresh()` to have populated `members`.
    public var isCurrentUserAdmin: Bool {
        // GroupHomeCoordinator already loads the group via groupsRepo.get(); the
        // current user's row lives in detail.members. Compute on demand.
        // If members aren't loaded yet, return false (conservative).
        members.first(where: { $0.member.userId == actorUserId })?.member.isFounder ?? false
    }
```

This requires `GroupHomeCoordinator` to know `actorUserId` AND store the members list. Currently it stores `memberCount: Int` (per the L1 implementer report). Extend the coordinator's state:

```swift
public let actorUserId: UUID
public var members: [MemberWithProfile] = []
```

Update the `init` to take `actorUserId: UUID`. Update `refresh()` to populate `members` from `detail.members` if `GroupDetail` carries them, or fall back to `groupsRepo.membersWithProfiles(of:)`. The implementer should pick whichever exposes the membership list cleanly — check `GroupDetail` struct first.

- [ ] **Step 2: Update GroupHomeCoordinator callers**

Find every `GroupHomeCoordinator(groupId:groupsRepo:)` instantiation:

```bash
grep -rn "GroupHomeCoordinator(" ios/Packages --include='*.swift' | grep -v "\.build"
```

Update each to pass `actorUserId: app.session?.user.id ?? UUID()` (or read from wherever the caller has access to it).

- [ ] **Step 3: Add admin-aware split to `GroupHomeView`'s "Miembros" nav row**

Open `GroupHomeView.swift`. In `communitySection`, the existing call passes `onOpenMembers` as a single callback. Change it to inspect `coordinator.isCurrentUserAdmin` at tap time:

```swift
navRow(
    icon: "person.2",
    label: "Miembros",
    trailing: { trailingValue("\(coordinator.memberCount)") },
    action: { coordinator.isCurrentUserAdmin ? onOpenMembersAdmin?() : onOpenMembersList?() }
)
```

Add two new optional callbacks (replacing the single `onOpenMembers`):

```swift
public var onOpenMembersList: (() -> Void)?
public var onOpenMembersAdmin: (() -> Void)?
```

Update the `init` and remove the old `onOpenMembers` parameter.

- [ ] **Step 4: Update `GroupHomeSheetContent` in `RootShellSheets.swift`**

The two callbacks need to wire through `router.openMembersList()` / `router.openMembersAdmin()`:

```swift
GroupHomeView(
    coordinator: coord,
    // ... other args unchanged ...
    onOpenMembersList: { router.openMembersList() },
    onOpenMembersAdmin: { router.openMembersAdmin() },
    // ... rest unchanged ...
)
```

Apply the same change in the `.inviteShare` block (which currently duplicates the .groupHome wiring per L1 Task 5's report).

- [ ] **Step 5: Delete `EditMembersSheet.swift`**

```bash
rm ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Members/EditMembersSheet.swift
rmdir ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Members 2>/dev/null || true
```

If the directory still has files (e.g., an extension or helper), leave it.

- [ ] **Step 6: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```

If errors mention `EditMembersSheet` — find the caller, replace with `router.openMembersAdmin()` (most likely the intent).

```bash
git add -A ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Groups/Members/ \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/GroupHomeCoordinator.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift \
       ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift && \
git commit -m "$(cat <<'EOF'
refactor(group): admin-aware members entry + kill EditMembersSheet

GroupHomeCoordinator now exposes isCurrentUserAdmin. The Miembros nav
row routes to MembersAdminView for admins (founders) and MembersListView
for everyone else. EditMembersSheet (578 L) deleted — its responsibilities
are fully covered by the two new views.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

- [ ] **Step 7: Tag**

```bash
git tag -a level2-pass1-complete -m "Level 2 redesign — Pass 1 (members surfaces split) complete"
```

---

## Pass 2 — Bulk invite + self-leave (Tasks 6-8)

### Task 6: Create `InviteMembersFromGroupView`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/InviteMembersFromGroupView.swift`

**Why:** Post-onboarding bulk invite. Today invite-by-phone only exists in the founder onboarding flow.

- [ ] **Step 1: Confirm invite repo + AppState exposure**

```bash
grep -n "inviteRepo\b\|InviteRepository" ios/Packages/RuulCore/Sources/RuulCore/AppState.swift | head -5
```

Expected: `app.inviteRepo: any InviteRepository`. If named differently, adapt.

- [ ] **Step 2: Create the view**

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct InviteMembersFromGroupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let group: RuulCore.Group

    @State private var newPhone: String = ""
    @State private var pending: [Invite] = []
    @State private var loading = false
    @State private var sending = false
    @State private var error: String?

    public init(group: RuulCore.Group) { self.group = group }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    shareCard
                    addManualSection
                    if !pending.isEmpty { pendingSection }
                    if let error {
                        Text(error)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle("Invitar miembros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { dismiss() } }
            }
            .task { await loadPending() }
        }
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Código de invitación")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            HStack {
                Text(group.inviteCode)
                    .ruulTextStyle(RuulTypography.mono)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                ShareLink(item: "Únete a \(group.name): \(group.inviteCode)") {
                    Label("Compartir", systemImage: "square.and.arrow.up")
                        .ruulTextStyle(RuulTypography.callout)
                }
            }
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        }
    }

    private var addManualSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Invitar por teléfono")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            HStack {
                TextField("+52 55 ...", text: $newPhone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .padding(RuulSpacing.md)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
                Button("Enviar") { Task { await sendInvite() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || newPhone.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Invitaciones pendientes (\(pending.count))")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: 0) {
                ForEach(pending, id: \.id) { invite in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.phoneE164 ?? "Sin teléfono")
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Text(relativeDateLabel(invite.createdAt))
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                        }
                        Spacer()
                        Text("Pendiente")
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .padding(RuulSpacing.md)
                    if invite.id != pending.last?.id {
                        Divider().background(Color.ruulSeparator)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        }
    }

    private func relativeDateLabel(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return "Enviada \(f.localizedString(for: date, relativeTo: .now))"
    }

    private func loadPending() async {
        loading = true
        defer { loading = false }
        do {
            pending = try await app.inviteRepo.listPending(group.id)
        } catch {
            self.error = "No pudimos cargar las invitaciones pendientes."
        }
    }

    private func sendInvite() async {
        let trimmed = newPhone.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await app.inviteRepo.createInvite(groupId: group.id, phoneE164: trimmed)
            newPhone = ""
            await loadPending()
        } catch {
            self.error = "No pudimos enviar la invitación."
        }
    }
}
```

NOTES:
- `Invite` model fields: `id`, `phoneE164: String?`, `createdAt: Date`. Confirm via `grep -n "public let\|public var" ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/Invite.swift` (or wherever Invite lives).
- `app.inviteRepo.listPending(_:)` and `createInvite(groupId:phoneE164:)` — confirm signatures.
- If `Invite.id: UUID` is `Identifiable` already, omit `id: \.id` and just use `ForEach(pending)`.

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/InviteMembersFromGroupView.swift && \
git commit -m "$(cat <<'EOF'
feat(members): InviteMembersFromGroupView — post-onboarding bulk invite

Reuses InviteRepository.createInvite + listPending. Share-link card +
manual phone entry + pending invites list. Wiring from GroupHome and
MembersAdminView lands in Task 8.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 7: Create `LeaveGroupConfirmationSheet`

**Files:**
- Create: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/LeaveGroupConfirmationSheet.swift`

**Why:** GroupHome.AVANZADO has a "Salir del grupo" row whose callback is currently a silent no-op. Adding a confirmation flow with the "single admin" guard makes self-leave safe.

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct LeaveGroupConfirmationSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let group: RuulCore.Group

    @State private var leaving = false
    @State private var members: [MemberWithProfile] = []
    @State private var loading = true
    @State private var error: String?

    public init(group: RuulCore.Group) { self.group = group }

    private var isSoleAdmin: Bool {
        guard let uid = app.session?.user.id else { return false }
        let admins = members.filter { $0.member.isFounder && $0.member.active }
        return admins.count == 1 && admins.first?.member.userId == uid
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                if loading {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity)
                } else if isSoleAdmin {
                    soleAdminBlocker
                } else {
                    confirmation
                }
                if let error {
                    Text(error)
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulNegative)
                }
                Spacer()
            }
            .padding(RuulSpacing.lg)
            .navigationTitle("Salir del grupo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await loadMembers() }
        }
    }

    private var soleAdminBlocker: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Label("Eres el único admin", systemImage: "exclamationmark.triangle")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulWarning)
            Text("Antes de salir, transfiere admin a otro miembro o archiva el grupo.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Button("Entendido") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("¿Salir de \(group.name)?")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Perderás acceso a este grupo y a su actividad.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
            Button(role: .destructive) {
                Task { await leave() }
            } label: {
                if leaving {
                    ProgressView()
                } else {
                    Text("Salir del grupo")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ruulNegative)
            .disabled(leaving)
        }
    }

    private func loadMembers() async {
        loading = true
        defer { loading = false }
        do {
            members = try await app.groupsRepo.membersWithProfiles(of: group.id)
        } catch {
            self.error = "No pudimos verificar tu rol."
        }
    }

    private func leave() async {
        leaving = true
        defer { leaving = false }
        do {
            try await app.groupsRepo.leave(group.id)
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "No pudimos salir. Intenta de nuevo."
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/LeaveGroupConfirmationSheet.swift && \
git commit -m "$(cat <<'EOF'
feat(members): LeaveGroupConfirmationSheet with sole-admin guard

Loads membership before showing the confirmation. If the calling user
is the only active founder, the sheet shows a blocker telling them to
transfer admin or archive first. Otherwise it presents a destructive
confirm button that calls GroupsRepository.leave.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)"
```

---

### Task 8: Wire invite + leave into `GroupHomeView` + `MembersAdminView`

**Files:**
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift`
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift` (`GroupHomeSheetContent`)
- Modify: `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersAdminView.swift` (toolbar invite tap)

**Why:** Final Pass 2 wiring.

- [ ] **Step 1: Add invite-from-group row + leave callback wiring to `GroupHomeView`**

In `GroupHomeView.swift`:

Add to the optional callback set:

```swift
public var onInviteMembers: (() -> Void)?
public var onConfirmLeave: (() -> Void)?
```

Update `init` accordingly.

In `communitySection`, add a row visible only when admin:

```swift
if coordinator.isCurrentUserAdmin {
    divider
    navRow(
        icon: "person.crop.circle.badge.plus",
        label: "Invitar miembros",
        action: { onInviteMembers?() }
    )
}
```

Replace the existing `onLeaveGroup` row's `action: onLeaveGroup` with `action: { onConfirmLeave?() ?? onLeaveGroup() }`. Or, if cleaner, just deprecate `onLeaveGroup` and use only `onConfirmLeave`.

- [ ] **Step 2: Wire in `GroupHomeSheetContent` (RootShellSheets.swift)**

Add to the private struct:

```swift
@State private var showInvite = false
@State private var showLeave = false
```

Pass new callbacks:

```swift
onConfirmLeave: { showLeave = true },
onInviteMembers: { showInvite = true }
```

Add modals to the existing chain at the bottom of `GroupHomeView(...)`:

```swift
.fullScreenCover(isPresented: $showInvite) {
    InviteMembersFromGroupView(group: group)
}
.fullScreenCover(isPresented: $showLeave) {
    LeaveGroupConfirmationSheet(group: group)
}
```

- [ ] **Step 3: Wire toolbar invite button in `MembersAdminView`**

`MembersAdminView` already exposes `onInviteTap: (() -> Void)?`. In the `.fullScreenCover(isPresented: boolBinding(for: .membersAdmin))` block (in RootShellSheets), wrap the inner state to manage a sheet flag, OR present `InviteMembersFromGroupView` directly via a navigation push. Simplest:

In the `.membersAdmin` cover block, replace:

```swift
MembersAdminView(coordinator: ...)
```

with:

```swift
MembersAdminViewWrapper(group: activeGroup, uid: uid, app: app)
```

And add a private wrapper struct at the bottom of `RootShellSheets.swift`:

```swift
@MainActor
private struct MembersAdminViewWrapper: View {
    let group: RuulCore.Group
    let uid: UUID
    let app: AppState
    @State private var showInvite = false

    var body: some View {
        MembersAdminView(
            coordinator: MembersCoordinator(group: group, actorUserId: uid, groupsRepo: app.groupsRepo),
            onInviteTap: { showInvite = true }
        )
        .environment(app)
        .fullScreenCover(isPresented: $showInvite) {
            InviteMembersFromGroupView(group: group)
        }
    }
}
```

- [ ] **Step 4: Build + commit + tag**

```bash
xcodebuild -project ios/Tandas.xcodeproj -scheme Tandas -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
git add ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Group/Views/GroupHomeView.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Shell/RootShellSheets.swift \
        ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Members/Views/MembersAdminView.swift && \
git commit -m "$(cat <<'EOF'
feat(members): wire bulk invite + self-leave from GroupHome

GroupHome.COMUNIDAD adds "Invitar miembros" row for admins; AVANZADO's
"Salir del grupo" now presents LeaveGroupConfirmationSheet with the
sole-admin guard. MembersAdminView's toolbar "+" opens the same invite
view as a wrapped fullScreenCover.

Co-Authored-By: claude-flow <ruv@ruv.net>
EOF
)" && \
git tag -a level2-pass2-complete -m "Level 2 redesign — Pass 2 (bulk invite + self-leave) complete"
```

---

## Done When

- All 8 tasks committed.
- `EditMembersSheet.swift` deleted.
- `GroupHomeView → Miembros` routes admin to `MembersAdminView` and others to `MembersListView`.
- `MembersAdminView` toolbar opens `InviteMembersFromGroupView`.
- `GroupHome → COMUNIDAD → Invitar miembros` (admin-only) opens the same.
- `GroupHome → AVANZADO → Salir del grupo` opens `LeaveGroupConfirmationSheet` with the sole-admin guard.
- `xcodebuild build` clean.
- Two tags: `level2-pass1-complete`, `level2-pass2-complete`.

---

## Out of Scope

- Pass 3 (role change RPC + role picker UI — separate plan, requires migration)
- Pass 4 (ex-members view, pending invites tab)
- Pass 5 (display_name_override editor, turn order error UX)
- `MemberDetailView` enhancements (joined_via subtitle, on_committee toggle) — Pass 3
