import SwiftUI
import RuulCore

/// Inbox tab. Wraps InboxView (filter chips + ActionInboxView) inside a
/// NavigationStack. Coordinator flows in from RootShell; when nil, shows
/// a ProgressView placeholder (bootstrap hasn't populated it yet).
///
/// Navigation callbacks are wired to RootRouter via @Environment injection.
@MainActor
public struct InboxTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router

    let coordinator: InboxCoordinator?

    public init(inbox: InboxCoordinator?) {
        self.coordinator = inbox
    }

    public var body: some View {
        NavigationStack {
            if let coord = coordinator {
                InboxView(coordinator: coord) { action in
                    Task { await dispatch(action) }
                }
                .environment(app)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ruulAppToolbar()
            }
        }
    }

    // MARK: - Inbox action dispatch
    // Mirrors HomeTab.handleInboxAction verbatim.

    private func dispatch(_ action: UserAction) async {
        // Inbox is cross-group; if the action's group isn't the
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
        case .slotPending, .contributionDue, .compensationDue, .assetActionApproval:
            break
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
