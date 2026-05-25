import SwiftUI
import RuulCore
import RuulUI

/// Screen-builder helpers for `RootShellSheets`. Each method instantiates
/// a coordinator and returns the SwiftUI view that the corresponding
/// sheet/cover modifier presents.
///
/// Extracted from `RootShellSheets.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/01_architecture.md §3
/// "Shell/RootShellSheets.swift (1108 LOC) — SPLIT". Members are
/// `internal` (no modifier) instead of `private` since Swift extensions
/// across files can't share `private` scope; the visibility loosens
/// from file-private to module-internal, still inaccessible to
/// downstream packages.
extension RootShellSheets {

    @MainActor
    func ruleEditSheet(_ ctx: RuleEditRouteContext) -> some View {
        let userId = app.session?.user.id ?? UUID()
        let memberDirectory = router.state.memberDirectory
        let currentMember = memberDirectory[userId]?.member
            ?? fallbackMember(userId: userId, groupId: ctx.group.id)
        let editCoord = EditRulesCoordinator(
            group: ctx.group,
            currentMember: currentMember,
            actorUserId: userId,
            governance: app.governance,
            policyRepo: app.policyRepo,
            ruleRepo: app.ruleRepo,
            voteRepo: app.voteRepo,
            userActionRepo: app.userActionRepo
        )
        return NavigationStack {
            EditRuleSheet(
                rule: ctx.rule,
                pending: nil,
                prefilledAmount: ctx.proposedAmount,
                pendingActionId: ctx.pendingActionId,
                coordinator: editCoord,
                onDismiss: {
                    while router.state.activeRoutes.contains(where: { if case .ruleEdit = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                }
            )
        }
    }

    @MainActor
    func eventDetailScreen(_ event: Event) -> some View {
        guard let group = app.groups.first(where: { $0.id == event.groupId }) else {
            return AnyView(EmptyView())
        }
        let userId = app.session?.user.id ?? UUID()
        let memberDirectory = router.state.memberDirectory
        let calendarService = router.state.calendarService
        // Consume + clear the initial-action hint set by openEvent(_:initialAction:).
        // Reading once and clearing guarantees back-then-reopen lands on
        // Overview (the default) instead of re-firing the share/scanner.
        let pending = router.state.pendingEventInitialAction
        router.state.pendingEventInitialAction = nil
        let initialSheet: EventDetailHost.Sheet? = (pending == .share) ? .share : nil
        let autoScanner = (pending == .scanner)
        return AnyView(
            EventDetailHost(
                event: event,
                group: group,
                currentUserId: userId,
                memberDirectory: memberDirectory,
                calendarService: calendarService,
                onClose: {
                    router.state.activeEvent = nil
                    while router.state.activeRoutes.contains(where: { if case .eventDetail = $0 { return true }; return false }) {
                        router.state.dismissTop()
                    }
                },
                onEditEvent: { editEvent in
                    router.state.activeEditEvent = editEvent
                    router.present(.editEvent)
                },
                onScannerOpen: { detail in
                    openScanner(for: detail)
                },
                initialSheet: initialSheet,
                autoOpenScanner: autoScanner
            )
            .environment(app)
            .environment(router)
            // The edit cover lives INSIDE the detail screen so SwiftUI
            // can present it above the detail's own fullScreenCover.
            // Attaching at root level (where other covers live) makes it
            // a sibling — and SwiftUI only renders one sibling cover at
            // a time, so the edit silently never appeared while the
            // detail was up. See activeEditEventItem binding.
            .fullScreenCover(item: activeEditEventItem) { wrappedEvent in
                eventEditScreen(wrappedEvent.event)
                    .presentationBackground(.ultraThinMaterial)
            }
        )
    }

    @MainActor @ViewBuilder
    func eventEditScreen(_ event: Event) -> some View {
        if let group = app.groups.first(where: { $0.id == event.groupId }) {
            let editCoord = ResourceEditCoordinator(
                event: event,
                group: group,
                eventRepo: app.eventRepo,
                analytics: EventAnalytics(analytics: app.analytics)
            )
            EditEventView(coordinator: editCoord)
                .onChange(of: editCoord.updatedEvent) { _, newValue in
                    guard newValue != nil else { return }
                    Task {
                        await router.state.homeCoordinator?.refresh(force: true)
                        if let updated = newValue {
                            router.state.activeEvent = updated
                        }
                    }
                }
        }
    }

    @MainActor
    func fineDetailScreen(_ fine: Fine) -> some View {
        let userId = app.session?.user.id ?? UUID()
        let coordinator = FineDetailCoordinator(
            fine: fine,
            userId: userId,
            fineRepo: app.fineRepo,
            appealRepo: app.appealRepo,
            analytics: app.analytics,
            changeFeed: app.multiDeviceChangeFeed
        )
        let onClose = {
            router.state.activeFine = nil
            while router.state.activeRoutes.contains(where: {
                if case .fineDetail = $0 { return true }
                return false
            }) {
                router.state.dismissTop()
            }
        }
        return NavigationStack {
            FineDetailHost(
                coordinator: coordinator,
                onViewAppeal: { appeal in
                    router.openVoteOnAppeal(AppealRouteContext(appeal: appeal, fine: fine))
                }
            )
            .ruulSheetToolbar("Multa", onClose: onClose)
        }
        .environment(app)
    }

    // V2 Slice 4D: myFinesScreen builder removed. MyFinesScreenHost now
    // lives in ProfileTab's local .fullScreenCover; cross-tab entries
    // go through `router.requestOpenMyFines()` → ProfileTab observes
    // the `pendingOpenMyFines` flag and presents.

    @MainActor @ViewBuilder
    var pastEventsScreen: some View {
        if let group = app.activeGroup, let userId = app.session?.user.id {
            NavigationStack {
                PastResourcesView(
                    group: group,
                    userId: userId,
                    eventRepo: app.eventRepo
                ) { event in
                    router.openEvent(event)
                }
                .ruulSheetToolbar("Eventos pasados", onClose: {
                    while router.state.contains(.past) {
                        router.state.dismissTop()
                    }
                })
            }
            .environment(app)
        }
    }

    @MainActor @ViewBuilder
    func voteDetailScreen(_ ctx: VoteDetailRouteContext) -> some View {
        let userId = app.session?.user.id ?? UUID()
        let memberDirectory = router.state.memberDirectory
        let group = app.groups.first(where: { $0.id == ctx.vote.groupId })
        let userMemberId = memberDirectory[userId]?.member.id ?? UUID()
        NavigationStack {
            if let group {
                VoteDetailHost(coordinator: VoteDetailCoordinator(
                    vote: ctx.vote,
                    group: group,
                    userMemberId: userMemberId,
                    voteRepo: app.voteRepo,
                    castRepo: app.voteCastRepo,
                    analytics: app.analytics,
                    changeFeed: app.multiDeviceChangeFeed
                ))
                .ruulSheetToolbar("Votación", onClose: {
                    while router.state.activeRoutes.contains(where: {
                        if case .voteDetail = $0 { return true }
                        return false
                    }) {
                        router.state.dismissTop()
                    }
                })
            } else {
                Text("Grupo no encontrado")
                    .foregroundStyle(Color.secondary)
                    .padding()
            }
        }
        .environment(app)
    }

    @MainActor @ViewBuilder
    func voteOnAppealSheet(_ ctx: AppealRouteContext) -> some View {
        let memberDirectory = router.state.memberDirectory
        let appellantName: String = {
            if let entry = memberDirectory.values.first(where: { $0.member.id == ctx.appeal.appellantMemberId }) {
                return entry.displayName
            }
            return "Un miembro"
        }()
        VoteOnAppealSheet(
            isPresented: appealPresentedBinding,
            fine: ctx.fine,
            appeal: ctx.appeal,
            appellantName: appellantName,
            voteCounts: nil
        ) { choice in
            Task {
                try? await app.appealRepo.castVote(appealId: ctx.appeal.id, choice: choice)
                await router.state.refreshInboxes()
            }
        }
    }
}
