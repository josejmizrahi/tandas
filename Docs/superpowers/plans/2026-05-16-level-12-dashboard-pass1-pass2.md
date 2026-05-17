# Level 12 GroupHome Dashboard — Pass 1 + Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Add a "Resumen" stat tile section + workflow shortcuts (votes/inbox) to `GroupHomeView`.

**Architecture:** Pass 1 creates `GroupSummary` model + `GroupSummaryRepository` that aggregates from existing repos (balance, fines, votes, user_actions). Pass 2 wires display + shortcuts into `GroupHomeView`.

**Tech Stack:** SwiftUI iOS 26+, Swift 6, no new BE migrations (reuses existing views).

**Source spec:** `docs/superpowers/specs/2026-05-16-level-12-projections-dashboard.md`.

---

## Verified facts

- `BalanceRepository.balancesForGroup(_ groupId: UUID) -> [MemberBalance]`. `MemberBalance.memberId: UUID` (group_members.id, NOT user_id) + `netCents: Int64` + `currency: String`.
- `FineRepository.myFines(userId: UUID) -> [Fine]` — cross-group; filter by `fine.groupId` to scope.
- `VoteRepository.openVotes(for groupId: UUID) -> [Vote]`.
- `UserActionRepository.pending(userId: UUID, groupId: UUID?) -> [UserAction]`.
- `GroupsRepository.members(of: UUID)` for memberCount + user_id → member_id resolution.
- `ResourceRepository.list(in:types:statuses:limit:)` for upcoming events count.
- `app.balanceRepo`, `app.fineRepo`, `app.voteRepo`, `app.userActionRepo`, `app.groupsRepo`, `app.resourceRepo` all confirmed exist.
- `GroupHomeCoordinator` already has `members: [MemberWithProfile]` (resolved from L1 fix) — can reuse for memberCount + member_id lookup.

---

## Pass 1 — Summary repo + model (3 tasks)

### Task 1: `GroupSummary` model

Create `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/GroupSummary.swift`:

```swift
import Foundation

/// Aggregated stats for a group, computed from existing projections.
/// Sendable + Hashable so SwiftUI can diff it cheaply.
public struct GroupSummary: Sendable, Hashable, Codable {
    public let memberCount: Int
    public let upcomingEventsCount: Int
    public let myBalanceCents: Int64
    public let myBalanceCurrency: String
    public let pendingFinesCount: Int
    public let pendingFinesOutstandingCents: Int64
    public let openVotesCount: Int
    public let pendingActionsCount: Int

    public init(
        memberCount: Int,
        upcomingEventsCount: Int,
        myBalanceCents: Int64,
        myBalanceCurrency: String,
        pendingFinesCount: Int,
        pendingFinesOutstandingCents: Int64,
        openVotesCount: Int,
        pendingActionsCount: Int
    ) {
        self.memberCount = memberCount
        self.upcomingEventsCount = upcomingEventsCount
        self.myBalanceCents = myBalanceCents
        self.myBalanceCurrency = myBalanceCurrency
        self.pendingFinesCount = pendingFinesCount
        self.pendingFinesOutstandingCents = pendingFinesOutstandingCents
        self.openVotesCount = openVotesCount
        self.pendingActionsCount = pendingActionsCount
    }

    public static let empty = GroupSummary(
        memberCount: 0,
        upcomingEventsCount: 0,
        myBalanceCents: 0,
        myBalanceCurrency: "MXN",
        pendingFinesCount: 0,
        pendingFinesOutstandingCents: 0,
        openVotesCount: 0,
        pendingActionsCount: 0
    )
}
```

Build + commit.

### Task 2: `GroupSummaryRepository`

Create `ios/Packages/RuulCore/Sources/RuulCore/Repositories/GroupSummaryRepository.swift`:

```swift
import Foundation
import OSLog

public protocol GroupSummaryRepository: Actor {
    /// Computes a stat snapshot for the group, scoped to the caller's perspective
    /// (e.g., myBalance is the caller's net balance within this group).
    func summary(groupId: UUID, userId: UUID) async throws -> GroupSummary
}

public actor MockGroupSummaryRepository: GroupSummaryRepository {
    public var seed: GroupSummary
    public init(seed: GroupSummary = .empty) { self.seed = seed }
    public func summary(groupId: UUID, userId: UUID) async throws -> GroupSummary { seed }
}

public actor LiveGroupSummaryRepository: GroupSummaryRepository {
    private let groupsRepo: any GroupsRepository
    private let resourceRepo: any ResourceRepository
    private let balanceRepo: any BalanceRepository
    private let fineRepo: any FineRepository
    private let voteRepo: any VoteRepository
    private let userActionRepo: any UserActionRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.summary")

    public init(
        groupsRepo: any GroupsRepository,
        resourceRepo: any ResourceRepository,
        balanceRepo: any BalanceRepository,
        fineRepo: any FineRepository,
        voteRepo: any VoteRepository,
        userActionRepo: any UserActionRepository
    ) {
        self.groupsRepo = groupsRepo
        self.resourceRepo = resourceRepo
        self.balanceRepo = balanceRepo
        self.fineRepo = fineRepo
        self.voteRepo = voteRepo
        self.userActionRepo = userActionRepo
    }

    public func summary(groupId: UUID, userId: UUID) async throws -> GroupSummary {
        // Fan-out: 6 independent queries in parallel.
        async let membersTask: [Member] = (try? await groupsRepo.members(of: groupId)) ?? []
        async let eventsTask: [ResourceRow] = (try? await resourceRepo.list(
            in: groupId,
            types: [.event],
            statuses: nil,
            limit: 100
        )) ?? []
        async let balancesTask: [MemberBalance] = (try? await balanceRepo.balancesForGroup(groupId)) ?? []
        async let finesTask: [Fine] = (try? await fineRepo.myFines(userId: userId)) ?? []
        async let votesTask: [Vote] = (try? await voteRepo.openVotes(for: groupId)) ?? []
        async let actionsTask: [UserAction] = (try? await userActionRepo.pending(userId: userId, groupId: groupId)) ?? []

        let members = await membersTask
        let events = await eventsTask
        let balances = await balancesTask
        let myFinesAll = await finesTask
        let votes = await votesTask
        let actions = await actionsTask

        // Resolve user_id → member_id for this group to filter balances.
        let myMemberId = members.first(where: { $0.userId == userId })?.id
        let myBalance = balances.first(where: { $0.memberId == myMemberId })

        // Filter fines to this group only (myFines is cross-group).
        let myGroupFines = myFinesAll.filter { $0.groupId == groupId }
        let pendingFines = myGroupFines.filter { fine in
            fine.status == .officialized && !fine.paid && !fine.waived
        }
        let outstanding = pendingFines.reduce(Int64(0)) { sum, fine in
            sum + Int64(truncatingIfNeeded: NSDecimalNumber(decimal: fine.amount).intValue * 100)
        }

        // Upcoming events = future events (filter by status not closed/cancelled).
        // V1: count all event-type resources; refine to "future" if metadata has starts_at.
        let upcoming = events.filter { $0.status == "open" }.count

        return GroupSummary(
            memberCount: members.count,
            upcomingEventsCount: upcoming,
            myBalanceCents: myBalance?.netCents ?? 0,
            myBalanceCurrency: myBalance?.currency ?? "MXN",
            pendingFinesCount: pendingFines.count,
            pendingFinesOutstandingCents: outstanding,
            openVotesCount: votes.count,
            pendingActionsCount: actions.count
        )
    }
}
```

NOTES:
- Confirm `Fine.amount: Decimal` vs `amountCents: Int` — adapt the outstanding calc accordingly. If `Fine.amount` is `Decimal` representing MXN units, multiply by 100 for cents. If already `amountCents`, use directly.
- Confirm `Fine.status` enum + cases (`officialized`, etc.) and `paid: Bool`, `waived: Bool` flags from existing `MyFinesCoordinator`.

Build + commit.

### Task 3: AppState wiring

Modify `AppState.swift`:
- Add `public var groupSummaryRepo: (any GroupSummaryRepository)?` (optional, same pattern as `myActivityRepo`).
- Mock initializer leaves it nil or assigns MockGroupSummaryRepository.

Modify `TandasApp.swift` (or wherever AppState is constructed in live mode):
- Add `state.groupSummaryRepo = LiveGroupSummaryRepository(groupsRepo: state.groupsRepo, resourceRepo: state.resourceRepo, balanceRepo: state.balanceRepo, fineRepo: state.fineRepo, voteRepo: state.voteRepo, userActionRepo: state.userActionRepo)` after all sub-repos are wired.

Build + commit + tag:

```bash
git tag -a level12-pass1-complete -m "Level 12 — Pass 1 (summary repo + model) complete"
```

---

## Pass 2 — GroupHomeView dashboard (3 tasks)

### Task 4: `GroupHomeCoordinator.summary`

Modify `Features/Group/GroupHomeCoordinator.swift`:

```swift
public var summary: GroupSummary?

public func loadSummary(userId: UUID) async {
    guard let repo = appStateRef?.groupSummaryRepo else { return }
    do {
        self.summary = try await repo.summary(groupId: groupId, userId: userId)
    } catch {
        log.warning("group summary load failed: \(error.localizedDescription, privacy: .public)")
    }
}
```

NOTE: how the coordinator accesses `app` varies — read the existing `refresh()` to see if it uses `app.groupsRepo` injected or passed-in. If passed-in via init, you may need to inject `groupSummaryRepo` separately. If accessed via env, use env reference.

Modify `refresh()` to launch `async let` for summary in parallel with detail fetch:

```swift
public func refresh() async {
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
        async let detailTask = groupsRepo.get(groupId)
        async let summaryTask: Void = loadSummary(userId: actorUserId)
        let detail = try await detailTask
        _ = await summaryTask
        self.group = detail.group
        // ... existing
    } catch { ... }
}
```

Build + commit.

### Task 5: `summarySection` stat tiles in GroupHomeView

Modify `Features/Group/Views/GroupHomeView.swift`:

Add new section between `hero` and `configurationSection`:

```swift
@ViewBuilder
private var summarySection: some View {
    if let summary = coordinator.summary {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("RESUMEN")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            HStack(spacing: RuulSpacing.sm) {
                statTile(value: "\(summary.memberCount)", label: "Miembros", action: { onOpenMembersList?() })
                statTile(value: "\(summary.upcomingEventsCount)", label: "Próximos", action: nil)
                statTile(
                    value: formatCurrency(summary.myBalanceCents, currency: summary.myBalanceCurrency),
                    label: "Mi balance",
                    action: { onOpenMyLedger?() }
                )
                if summary.pendingFinesCount > 0 {
                    statTile(
                        value: formatCurrency(summary.pendingFinesOutstandingCents, currency: summary.myBalanceCurrency),
                        label: "Multas",
                        action: { onOpenMyFines?() }
                    )
                }
            }
        }
    }
}

@ViewBuilder
private func statTile(value: String, label: String, action: (() -> Void)?) -> some View {
    let content = VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
        Text(value)
            .ruulTextStyle(RuulTypography.statMedium)
            .foregroundStyle(Color.ruulTextPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        Text(label.uppercased())
            .ruulTextStyle(RuulTypography.sectionLabel)
            .foregroundStyle(Color.ruulTextTertiary)
            .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(RuulSpacing.md)
    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
    .overlay(
        RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5)
    )

    if let action {
        Button(action: action) { content }
            .buttonStyle(.plain)
    } else {
        content
    }
}

private func formatCurrency(_ cents: Int64, currency: String) -> String {
    let units = Double(cents) / 100.0
    let nf = NumberFormatter()
    nf.numberStyle = .currency
    nf.currencyCode = currency
    nf.maximumFractionDigits = 0
    return nf.string(from: NSNumber(value: units)) ?? "\(currency) \(Int(units))"
}
```

Add `onOpenMyLedger: (() -> Void)?` + `onOpenMyFines: (() -> Void)?` callbacks to GroupHomeView init (optional, nil-default).

Insert `summarySection` in the body between `hero` and `configurationSection`.

NOTE: confirm `RuulTypography.statMedium` exists; if not, fall back to `RuulTypography.title3` or `.title2`.

Build + commit.

### Task 6: Workflow shortcuts + tag

In the same `GroupHomeView.swift`, extend `communitySection` to add workflow shortcut rows (only when count > 0):

```swift
private var communitySection: some View {
    sectionContainer(title: "COMUNIDAD") {
        navRow(
            icon: "person.2",
            label: "Miembros",
            trailing: { trailingValue("\(coordinator.memberCount)") },
            action: { coordinator.isCurrentUserAdmin ? onOpenMembersAdmin?() : onOpenMembersList?() }
        )
        if coordinator.isCurrentUserAdmin {
            divider
            navRow(
                icon: "person.crop.circle.badge.plus",
                label: "Invitar miembros",
                action: { onInviteMembers?() }
            )
        }
        if let summary = coordinator.summary, summary.openVotesCount > 0 {
            divider
            navRow(
                icon: "hand.raised",
                label: "\(summary.openVotesCount) votos abiertos",
                action: { onOpenVotes?() }
            )
        }
        if let summary = coordinator.summary, summary.pendingActionsCount > 0 {
            divider
            navRow(
                icon: "tray.fill",
                label: "\(summary.pendingActionsCount) acciones pendientes",
                action: { onOpenInbox?() }
            )
        }
    }
}
```

Add `onOpenVotes: (() -> Void)?` + `onOpenInbox: (() -> Void)?` callbacks. Wire from `RootShellSheets.GroupHomeSheetContent`:

```swift
onOpenVotes: { router.present(.openVotes(...)) },  // confirm route signature
onOpenInbox: { router.selectTab(.inbox) },
onOpenMyLedger: { router.openMyLedger() },         // confirm router method
onOpenMyFines: { router.openSanciones() },
```

Build + commit + tag:

```bash
git tag -a level12-pass2-complete -m "Level 12 — Pass 2 (dashboard + shortcuts) complete"
```

---

## Done When

- 6 tasks committed.
- GroupHomeView shows "RESUMEN" section with 3-4 stat tiles (Miembros, Próximos, Mi balance, Multas if any).
- Stat tiles are tappable where it makes sense (Miembros → list, Balance → MyLedger, Multas → MyFines).
- COMUNIDAD section conditionally shows "X votos abiertos" + "Y acciones pendientes" when count > 0.
- Build clean.
- Two tags: `level12-pass1-complete`, `level12-pass2-complete`.

---

## Out of Scope

- Per-resource summary inline en HomeView feed
- Realtime updates de summary
- Cross-group "todos mis grupos" dashboard
- Stat customization
- Group analytics histórico (gráficas)
- Push notifications cuando metrics cambian
