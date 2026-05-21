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
            if let event = try? await app.eventRepo.event(action.referenceId) {
                router.openEvent(event)
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
        case .assetActionApproval:
            // Mig 00226+00227: reference_id apunta directo al asset; el
            // admin revisa + resuelve desde el resource detail. V2
            // tendrá una vista de revisión dedicada.
            router.openResource(id: action.referenceId)
        case .slotPending:
            // reference_id = slot resource id (mig 00204). Abre el
            // resource detail polimórfico para que el usuario acepte/
            // decline el slot ofrecido.
            router.openResource(id: action.referenceId)
        case .contributionDue, .compensationDue:
            // Fund-related: el reference_id es el fund. Abre el detail
            // del fund donde el usuario puede contribuir o marcar
            // compensación. Sin esto el tap era no-op silencioso.
            router.openResource(id: action.referenceId)
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
