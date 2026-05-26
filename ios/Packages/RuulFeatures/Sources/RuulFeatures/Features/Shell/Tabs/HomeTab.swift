import SwiftUI
import RuulCore

/// Thin tab wrapper for Home. Embeds HomeView inside a NavigationStack.
/// Coordinators flow in from RootShell; when nil, shows a ProgressView
/// placeholder (bootstrap hasn't populated them yet).
///
/// Navigation callbacks are wired to RootRouter via @Environment injection.
@MainActor
public struct HomeTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let homeCoordinator: HomeCoordinator?
    let inboxCoordinator: InboxCoordinator?

    /// 2026-05-25 Bug-1 fix: `.fineProposalReview` actions now open the
    /// canonical `ReviewProposedFinesView` instead of routing to the
    /// event detail.
    @State private var reviewProposedFinesEvent: Event?
    /// Action id of the originating `.fineProposalReview` so the sheet
    /// can auto-resolve it server-side when the load returns zero fines.
    @State private var reviewProposedFinesActionId: UUID?

    public init(home: HomeCoordinator?, inbox: InboxCoordinator?) {
        self.homeCoordinator = home
        self.inboxCoordinator = inbox
    }

    public var body: some View {
        NavigationStack {
            if let coord = homeCoordinator {
                HomeOverviewView(
                    coordinator: coord,
                    inboxCoordinator: inboxCoordinator,
                    onInboxActionTap: { action in await handleInboxAction(action) },
                    userId: app.session?.user.id ?? UUID(),
                    onCreateEvent: { router.present(.createCover) },
                    onOpenEvent: { event in router.openEvent(event) },
                    onOpenPastEvents: { router.openPastEvents() },
                    onOpenGroupHistory: { router.openGroupHistory() },
                    onInvitePeople: { router.openInviteShare() },
                    onSwitchGroup: { router.openGroupSwitcher() }
                )
                .environment(app)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $reviewProposedFinesEvent) { event in
            ReviewProposedFinesSheet(
                event: event,
                pendingActionId: reviewProposedFinesActionId,
                onClose: {
                    reviewProposedFinesEvent = nil
                    reviewProposedFinesActionId = nil
                    // Inbox refresh so a freshly-resolved stale action
                    // disappears from the pendings cluster on next render.
                    if let inbox = inboxCoordinator {
                        Task { await inbox.refresh() }
                    }
                },
                onSelectFine: { fine in
                    reviewProposedFinesEvent = nil
                    reviewProposedFinesActionId = nil
                    router.openFine(fine)
                }
            )
            .environment(app)
            .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Inbox action dispatch
    // Mirrors MainTabView.handleInboxAction verbatim. The router handles
    // navigation outcomes; AppState repos provide async data fetches.

    private func handleInboxAction(_ action: UserAction) async {
        // 14.2 — Inbox is cross-group; if the action's group isn't the
        // currently active one, switch before opening the detail.
        if app.activeGroup?.id != action.groupId {
            app.activeGroupId = action.groupId
        }

        switch action.actionType {
        case .finePending:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                router.openFine(fine)
            }
        case .fineVoided:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                router.openFine(fine)
            }
        case .fineProposalReview:
            // Bug-1 fix: open the host's grace-period dashboard (proposed
            // fines for this event) instead of routing to the event detail.
            // referenceId IS event_id per mig 00044. The actionId is
            // captured so the sheet auto-resolves it when the event has
            // zero fines (stale-action cleanup).
            if let event = try? await app.eventRepo.event(action.referenceId) {
                reviewProposedFinesActionId = action.id
                reviewProposedFinesEvent = event
            }
        case .appealVotePending:
            if let appeal = try? await app.appealRepo.appeal(id: action.referenceId),
               let fine = try? await app.fineRepo.fine(id: appeal.fineId) {
                router.openVoteOnAppeal(AppealRouteContext(appeal: appeal, fine: fine))
            }
        case .rsvpPending:
            if let event = try? await app.eventRepo.event(action.referenceId) {
                router.selectTab(.home)
                router.openEvent(event)
            }
        case .ruleChangeApplyPending:
            await openRuleEditFromInbox(action: action)
        case .votePending:
            if let vote = try? await app.voteRepo.vote(id: action.referenceId) {
                router.openVoteDetail(VoteDetailRouteContext(vote: vote))
            }
        case .hostAssigned:
            if let event = try? await app.eventRepo.event(action.referenceId) {
                router.selectTab(.home)
                router.openEvent(event)
            }
        case .assetActionApproval, .slotPending,
             .contributionDue, .compensationDue:
            // Polymorphic resources (asset/slot/fund). Mirrors
            // `MyGroupsTab.handleInboxAction`: fetch the `ResourceRow`
            // so the cover mounts `ResourceDetailSheet` via
            // `router.openResource(_ row:)`. The legacy
            // `openResource(id:)` overload pushes `.eventDetail` and
            // is wrong for non-event types — that's why a tap on a
            // contribution-due action from Home used to land on the
            // event screen instead of the fund detail.
            if let row = try? await app.resourceRepo.resource(action.referenceId) {
                router.openResource(row)
            }
        }
    }

    private func openRuleEditFromInbox(action: UserAction) async {
        guard let vote = try? await app.voteRepo.vote(id: action.referenceId) else { return }
        guard case .object(let payload) = vote.payload,
              case .int(let proposedAmount) = payload["proposed_amount"] ?? .null
        else { return }

        let ruleId = vote.referenceId
        guard let group = app.groups.first(where: { $0.id == action.groupId }) else { return }

        guard let rules = try? await app.ruleRepo.list(groupId: group.id),
              let rule = rules.first(where: { $0.id == ruleId })
        else { return }

        router.handleRuleChange(
            rule: rule,
            group: group,
            proposedAmount: proposedAmount,
            pendingActionId: action.id
        )
    }
}
