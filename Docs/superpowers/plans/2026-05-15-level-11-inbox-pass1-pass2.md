# Level 11 Inbox UX — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Resolved-history chip + swipe-to-resolve + bulk-resolve in InboxView.

**Architecture:** Pass 1 extends `UserActionRepository` with `resolved(userId:limit:)` + adds "Resueltas" chip rendering greyed history. Pass 2 wraps ActionCard with swipe gesture + adds "Marcar todas" toolbar + toast.

**Tech Stack:** SwiftUI iOS 26+, Swift 6.

**Source spec:** `docs/superpowers/specs/2026-05-15-level-11-user-actions-inbox.md`.

---

## Verified facts

- `InboxChip` enum at `Features/Inbox/Views/InboxView.swift` line 7: cases `all`, `urgente`, `aprobaciones`, `votos`, `pagos`, `solicitudes`, `confirmar`, `recordatorios`. We add `resueltas`.
- `UserActionRepository` has `pending(userId:groupId:)`, `resolve(actionId:)`, `pendingCountsByGroup(userId:)`. We add `resolved(userId:limit:)`.
- `UserAction.resolvedAt: Date?` — non-nil when resolved.
- `ActionCard` lives in `RuulUI/Primitives/ActionCard.swift`. Has button-based tap; no swipe today.
- `app.userActionRepo: any UserActionRepository`.
- Modal/list patterns: standard SwiftUI `.swipeActions(edge:)`.

---

## Pass 1 — Resolved history chip (3 tasks)

### Task 1: Extend `UserActionRepository` with `resolved(userId:limit:)`

Modify `ios/Packages/RuulCore/Sources/RuulCore/Repositories/UserActionRepository.swift`:

Add to protocol:
```swift
/// Recent resolved actions for the user (cross-group, latest first).
func resolved(userId: UUID, limit: Int) async throws -> [UserAction]
```

Live impl:
```swift
public func resolved(userId: UUID, limit: Int) async throws -> [UserAction] {
    let rows: [UserAction] = try await client
        .from("user_actions")
        .select()
        .eq("user_id", value: userId.uuidString.lowercased())
        .not("resolved_at", operator: .is, value: AnyJSON.null)
        .order("resolved_at", ascending: false)
        .limit(limit)
        .execute()
        .value
    return rows
}
```

Confirm exact `.not(...)` API by reading the existing PostgREST patterns in the same file (Supabase Swift SDK syntax can vary). If the supabase-swift 2.20 API differs (e.g., `.not("resolved_at", value: "is.null")`), adapt — check by inspecting the existing `pending(...)` query.

Mock impl:
```swift
public func resolved(userId: UUID, limit: Int) async throws -> [UserAction] {
    Array(
        actions
            .filter { $0.userId == userId && $0.resolvedAt != nil }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
            .prefix(limit)
    )
}
```

(`actions` is the mock's in-memory store — confirm name with `grep -n "private var actions\|public var actions" ios/Packages/RuulCore/Sources/RuulCore/Repositories/UserActionRepository.swift`.)

Build + commit.

### Task 2: Add `.resueltas` to `InboxChip` enum

Modify `ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Inbox/Views/InboxView.swift`:

Add to enum:
```swift
case resueltas    = "Resueltas"
```

Add icon mapping:
```swift
case .resueltas:     return "checkmark.circle"
```

If `InboxChip` has a `priority`/`actionTypes` filter helper, add a special-case for `resueltas` that signals "use history fetch instead of pending filter".

Build + commit.

### Task 3: Render resolved list when chip = `resueltas`

Modify `InboxCoordinator` + InboxView (or wherever the chip→data switch happens):

Coordinator additions:
```swift
public private(set) var resolvedActions: [UserAction] = []

public func loadResolved(limit: Int = 50) async {
    do {
        resolvedActions = try await userActionRepo.resolved(userId: userId, limit: limit)
    } catch {
        // log; resolvedActions stays as-is
    }
}
```

InboxView: when `selectedChip == .resueltas`, call `coordinator.loadResolved()` in `.task(id: selectedChip)` and render `coordinator.resolvedActions`. Use a wrapper view (`ResolvedActionsList` or inline) that:
- Renders each action with `.opacity(0.6)`
- Replaces chevron with trailing text "Resuelta hace X" (RelativeDateTimeFormatter against `resolvedAt`)
- Disables tap (or tap shows nothing, doesn't try to navigate)

Build + commit + tag:

```bash
git tag -a level11-pass1-complete -m "Level 11 — Pass 1 (resolved history) complete"
```

---

## Pass 2 — Swipe + bulk + toast (3 tasks)

### Task 4: Swipe-to-resolve on ActionCard

Modify the caller of `ActionCard` (likely `ActionInboxView` or `FilteredInboxList`):

Wrap the existing tap rendering with `.swipeActions`:

```swift
ForEach(items) { action in
    ActionCard(...)  // existing
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { await coordinator.resolveQuick(action.id) }
            } label: {
                Label("Hecho", systemImage: "checkmark.circle.fill")
            }
            .tint(.green)
        }
}
```

Add `InboxCoordinator.resolveQuick(_:)`:
```swift
public func resolveQuick(_ actionId: UUID) async {
    do {
        try await userActionRepo.resolve(actionId: actionId)
        await refresh()  // re-fetch pending
    } catch {
        // log + show error toast (V1: silent fail acceptable)
    }
}
```

NOTE: `ActionCard` may not be in a `List` — if it's a LazyVStack, `.swipeActions` only works inside `List`. If so, alternative: wrap each card with a custom drag gesture or convert the section to a `List`. Test in sim. Fallback if it doesn't work in LazyVStack: defer to a long-press context menu with "Hecho" action.

Build + commit.

### Task 5: "Marcar todas" toolbar + confirmation alert

Modify `InboxView.swift`:

Add toolbar item:
```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        if coordinator.actions.count > 1 {
            Button("Marcar todas") { showBulkAlert = true }
        }
    }
}
.alert("¿Marcar las \(coordinator.actions.count) acciones como hechas?",
       isPresented: $showBulkAlert) {
    Button("Marcar", role: .destructive) {
        Task {
            let count = await coordinator.resolveAll()
            showToast(count: count)
        }
    }
    Button("Cancelar", role: .cancel) {}
}
```

Add `@State private var showBulkAlert = false` + `@State private var toastMessage: String?`.

Coordinator: `resolveAll()`:
```swift
public func resolveAll() async -> Int {
    let snapshot = actions
    var count = 0
    for action in snapshot {
        do {
            try await userActionRepo.resolve(actionId: action.id)
            count += 1
        } catch { }
    }
    await refresh()
    return count
}
```

Build + commit.

### Task 6: Toast feedback + tag

Add a simple toast overlay to InboxView:

```swift
.overlay(alignment: .bottom) {
    if let toastMessage {
        Text(toastMessage)
            .ruulTextStyle(RuulTypography.body)
            .padding(RuulSpacing.md)
            .background(Color.ruulSurface, in: Capsule())
            .shadow(radius: 4)
            .padding(.bottom, RuulSpacing.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
.animation(.easeInOut, value: toastMessage)

private func showToast(count: Int) {
    toastMessage = "\(count) acciones resueltas"
    Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await MainActor.run { toastMessage = nil }
    }
}
```

Build + commit + tag:

```bash
git tag -a level11-pass2-complete -m "Level 11 — Pass 2 (swipe + bulk + toast) complete"
```

---

## Done When

- 6 tasks committed.
- "Resueltas" chip shows resolved history greyed.
- Swipe right on action card → "Hecho" instantly resolves.
- "Marcar todas" toolbar (when N>1) bulk-resolves with confirmation + toast.
- Build clean.
- Two tags: `level11-pass1-complete`, `level11-pass2-complete`.

---

## Out of Scope

- Snooze (BE mig + UI)
- hostAssigned auto-resolver
- Real undo after bulk
- Pagination of resolved history
- Solicitudes chip (swap_request type)
- Analytics fix (open vs resolve event)
