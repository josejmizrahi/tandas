import SwiftUI
import RuulCore

/// Thin tab wrapper for the Group hub. Embeds GroupTabView inside a
/// NavigationStack. Requires both `rulesCoordinator` and an active group
/// from AppState; shows a ProgressView placeholder while either is absent.
///
/// Navigation callbacks are wired to RootRouter via @Environment injection.
@MainActor
public struct GroupTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let rulesCoordinator: RulesCoordinator?
    let myFinesCoordinator: MyFinesCoordinator?
    let inboxCoordinator: InboxCoordinator?
    let homeCoordinator: HomeCoordinator?

    public init(
        rules: RulesCoordinator?,
        myFines: MyFinesCoordinator?,
        inbox: InboxCoordinator?,
        home: HomeCoordinator?
    ) {
        self.rulesCoordinator = rules
        self.myFinesCoordinator = myFines
        self.inboxCoordinator = inbox
        self.homeCoordinator = home
    }

    public var body: some View {
        NavigationStack {
            if let rulesCoord = rulesCoordinator,
               let group = app.activeGroup {
                GroupTabView(
                    activeGroup: group,
                    userId: app.session?.user.id ?? UUID(),
                    rulesCoordinator: rulesCoord,
                    myFinesCoordinator: myFinesCoordinator,
                    inboxCoordinator: inboxCoordinator,
                    upcomingEvents: homeCoordinator?.upcomingEvents ?? [],
                    myRSVPs: homeCoordinator?.myRSVPs ?? [:],
                    onSwitchGroup: { router.openGroupSwitcher() },
                    onOpenEvent: { event in router.openEvent(event) },
                    onOpenFine: { fine in router.openFineDetail(fine.id) },
                    onOpenInboxAction: { action in await handleInboxAction(action) },
                    onCreateResource: { router.present(.createCover) },
                    onOpenAcuerdos: { router.openAcuerdos() },
                    onOpenDecisiones: { router.openOpenVotes(OpenVotesRouteContext(id: group.id)) },
                    onOpenSanciones: { router.openSanciones() },
                    onOpenGroupRules: { router.openGroupRulesSettings() },
                    onOpenActivity: { router.openGroupHistory() }
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
        if app.activeGroup?.id != action.groupId {
            app.activeGroupId = action.groupId
        }

        switch action.actionType {
        case .finePending:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                router.openFineDetail(fine.id)
            }
        case .fineVoided:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                router.openFineDetail(fine.id)
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
        case .slotPending, .contributionDue, .compensationDue:
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
