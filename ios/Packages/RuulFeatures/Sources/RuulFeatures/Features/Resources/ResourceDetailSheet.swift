import SwiftUI
import RuulUI
import RuulCore

/// Polymorphic resource detail sheet. Post the universal-detail rewrite
/// this view does just three things:
///   1. Load the resource's enabled capabilities from
///      `public.resource_capabilities`.
///   2. Resolve the parent Group + cache the member directory.
///   3. Build a `ResourceDetailContext` and hand it to
///      `UniversalResourceDetailView`, which composes the page out of
///      the catalog-registered capability sections.
///
/// Ledger + rules tap routes go through the polymorphic
/// `ResourceLedgerCoordinator` / `ResourceRulesCoordinator`, opening
/// `ResourceLedgerSheet` / `ResourceRulesSheet` on demand. Coordinator
/// instances are built lazily on first present so we don't pay for
/// them when the user doesn't tap.
public struct ResourceDetailSheet: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    public let resource: ResourceRow

    /// Live snapshot of the polymorphic row. Initially nil and falls back
    /// to the prop, gets populated after the first re-fetch (e.g. after
    /// an asset RPC that mutated `resources.metadata`). The context built
    /// for child views reads `liveResource ?? resource`, so the initial
    /// render uses the value the caller already had — no extra latency on
    /// open — and subsequent mutations bubble back via `onResourceMutated`.
    @State private var liveResource: ResourceRow?
    @State private var capabilities: [ResourceCapability] = []
    @State private var memberDirectory: [UUID: MemberWithProfile] = [:]
    @State private var resourceActions: [UserAction] = []
    @State private var ledgerSheetPresented: Bool = false
    @State private var ledgerCoordinator: ResourceLedgerCoordinator?
    @State private var rulesSheetPresented: Bool = false
    @State private var rulesCoordinator: ResourceRulesCoordinator?
    @State private var enableCapabilityPresented: Bool = false

    public init(resource: ResourceRow) { self.resource = resource }

    public var body: some View {
        NavigationStack {
            content
        }
        .task { await load() }
        .ruulSheet(isPresented: $ledgerSheetPresented) {
            if let ledgerCoordinator {
                ResourceLedgerSheet(
                    isPresented: $ledgerSheetPresented,
                    coordinator: ledgerCoordinator,
                    groupVocabulary: typeLabel.lowercased()
                )
            }
        }
        .onChange(of: ledgerSheetPresented) { _, presented in
            if presented && ledgerCoordinator == nil {
                ledgerCoordinator = makeLedgerCoordinator()
            }
        }
        .ruulSheet(isPresented: $rulesSheetPresented) {
            if let rulesCoordinator {
                ResourceRulesSheet(
                    isPresented: $rulesSheetPresented,
                    coordinator: rulesCoordinator
                )
            }
        }
        .onChange(of: rulesSheetPresented) { _, presented in
            if presented && rulesCoordinator == nil {
                rulesCoordinator = makeRulesCoordinator()
            }
        }
        .fullScreenCover(isPresented: $enableCapabilityPresented) {
            ManageCapabilitiesSheet(
                resourceId: resource.id,
                resourceType: resource.resourceType,
                enabled: capabilities.filter { $0.enabled },
                onChanged: {
                    // Refresh capabilities so the new section renders.
                    Task { await reloadCapabilities() }
                }
            )

        }
    }

    /// Light-weight reload after enabling a capability — only refetches
    /// the resource_capabilities rows, not the member directory or
    /// inbox actions.
    @MainActor
    private func reloadCapabilities() async {
        capabilities = (try? await app.resourceCapabilityRepo.list(resourceId: resource.id)) ?? []
    }

    /// Re-fetches the polymorphic row when a child section mutated
    /// `resources.metadata` (asset custody, transfer, checkout, etc.).
    /// Failures fall through silently — the user still sees the prior
    /// snapshot, and the next dismiss/reopen cycle picks up the change.
    @MainActor
    private func refreshResource() async {
        if let fresh = try? await app.resourceRepo.resource(resource.id) {
            liveResource = fresh
        }
    }

    /// Dispatches the `Necesita atención` tap. Mirrors the action-type
    /// switch in `HomeTab.handleInboxAction` so the same UserAction
    /// behaves consistently no matter where the user opens it (Inbox
    /// list, Home pendings strip, or here from a resource detail). For
    /// surfaces that already live on this screen (rsvp on an event-like
    /// resource, contribution on a fund) we resolve the action row so it
    /// stops nagging — the user is already at the right place.
    @MainActor
    private func handleInboxAction(_ action: UserAction) async {
        switch action.actionType {
        case .finePending, .fineVoided:
            if let fine = try? await app.fineRepo.fine(id: action.referenceId) {
                router.openFine(fine)
            }
        case .appealVotePending:
            if let appeal = try? await app.appealRepo.appeal(id: action.referenceId),
               let fine = try? await app.fineRepo.fine(id: appeal.fineId) {
                router.openVoteOnAppeal(AppealRouteContext(appeal: appeal, fine: fine))
            }
        case .votePending:
            if let vote = try? await app.voteRepo.vote(id: action.referenceId) {
                router.openVoteDetail(VoteDetailRouteContext(vote: vote))
            }
        case .fineProposalReview, .hostAssigned, .rsvpPending:
            // These reference an event that, for non-event resources,
            // isn't this resource. Open the event detail.
            if let event = try? await app.eventRepo.event(action.referenceId) {
                router.openEvent(event)
            }
        case .ruleChangeApplyPending:
            // Vote → rule → group fetch chain. Re-uses the same async
            // shape as HomeTab.openRuleEditFromInbox.
            guard let vote = try? await app.voteRepo.vote(id: action.referenceId),
                  case .object(let payload) = vote.payload,
                  case .int(let proposedAmount) = payload["proposed_amount"] ?? .null,
                  let group = app.groups.first(where: { $0.id == action.groupId }),
                  let rules = try? await app.ruleRepo.list(groupId: group.id),
                  let rule = rules.first(where: { $0.id == vote.referenceId })
            else { return }
            router.handleRuleChange(
                rule: rule,
                group: group,
                proposedAmount: proposedAmount,
                pendingActionId: action.id
            )
        case .slotPending, .contributionDue, .compensationDue:
            // Resource-scoped pendings — the user is already on the right
            // detail. Resolve so the badge disappears and refresh.
            try? await app.userActionRepo.resolve(actionId: action.id)
            await refreshResourceActions()
        }
    }

    @MainActor
    private func refreshResourceActions() async {
        guard let userId = app.session?.user.id else {
            resourceActions = []
            return
        }
        if let allActions = try? await app.userActionRepo.pending(
            userId: userId,
            groupId: resource.groupId
        ) {
            resourceActions = allActions.filter { $0.referenceId == resource.id }
        } else {
            resourceActions = []
        }
    }

    @ViewBuilder
    private var content: some View {
        if let group = parentGroup {
            UniversalResourceDetailView(context: context(for: group))
        } else {
            ZStack {
                Color.ruulBackgroundCanvas.ignoresSafeArea()
                RuulLoadingState()
            }
        }
    }

    private var parentGroup: RuulCore.Group? {
        app.groups.first(where: { $0.id == resource.groupId })
    }

    private func context(for group: RuulCore.Group) -> ResourceDetailContext {
        ResourceDetailContext(
            resource: liveResource ?? resource,
            group: group,
            currentUserId: app.session?.user.id,
            enabledCapabilities: enabledCapabilitySet,
            memberDirectory: memberDirectory,
            displayName: displayName,
            attentionActions: resourceActions,
            onPresentLedger: { ledgerSheetPresented = true },
            onPresentRules:  { rulesSheetPresented = true },
            // Non-event resources don't surface the "Editar detalles" menu
            // item — commonSecondaryActions in CapabilityResolver doesn't
            // include `.editDetails` for fund / asset / slot / space, so
            // this closure is never invoked from the current entry points.
            // Events route through EventDetailHost which wires its own
            // edit path. Keep as no-op rather than crashing if a future
            // resource type opts back in before its editor exists.
            onPresentEditResource:     { },
            onPresentEnableCapability: { enableCapabilityPresented = true },
            onOpenInboxAction: { action in
                await handleInboxAction(action)
            },
            onResourceMutated: { await refreshResource() }
        )
    }

    private var enabledCapabilitySet: Set<String> {
        Set(capabilities.filter { $0.enabled }.map { $0.capabilityBlockId })
    }

    // MARK: - Sub-coordinators

    /// Builds the polymorphic ledger coordinator on first ledger sheet
    /// present. Reuses the resource's group_id + id so the listForResource
    /// query hits the right ledger_entries rows.
    private func makeLedgerCoordinator() -> ResourceLedgerCoordinator {
        let ctx = ResourceLedgerContext(
            groupId: resource.groupId,
            resourceId: resource.id,
            resourceType: resourceTypeString,
            displayName: displayName,
            currentUserId: app.session?.user.id ?? UUID()
        )
        return ResourceLedgerCoordinator(
            context: ctx,
            ledgerRepo: app.ledgerRepo,
            groupsRepo: app.groupsRepo,
            policyRepo: app.policyRepo
        )
    }

    /// Builds the polymorphic rules coordinator. `canCreate` is the
    /// server-side gate predicate. V1 mirrors the legacy behavior:
    /// founders + admins can create; everyone else reads only. The
    /// gate hardens in the governance plan (Tasks 8-10) once
    /// resolve_governance is fully wired into RuleRepository mutations.
    private func makeRulesCoordinator() -> ResourceRulesCoordinator {
        let ctx = ResourceRuleContext(
            groupId: resource.groupId,
            resourceId: resource.id,
            resourceType: resourceTypeString,
            displayName: displayName,
            canCreate: isFounder
        )
        return ResourceRulesCoordinator(
            context: ctx,
            ruleRepo: app.ruleRepo,
            shapeRegistry: app.ruleShapeRegistry
        )
    }

    /// True when the current user created the parent group. The
    /// ResourceRulesCoordinator's CTA stays hidden when this is false;
    /// the server still gates the write at the RPC level.
    private var isFounder: Bool {
        guard let userId = app.session?.user.id,
              let group = parentGroup else { return false }
        return group.createdBy == userId
    }

    /// Raw wire-format string for the resource type ("event", "fund", etc.).
    /// Feeds `ResourceLedgerContext` and `ResourceRuleContext` which use it
    /// for analytics / catalog filtering — not user-facing display.
    private var resourceTypeString: String { resource.resourceType.rawString }

    @MainActor
    private func load() async {
        async let capsTask = app.resourceCapabilityRepo.list(resourceId: resource.id)
        async let membersTask = app.groupsRepo.membersWithProfiles(of: resource.groupId)
        capabilities = (try? await capsTask) ?? []
        let members = (try? await membersTask) ?? []
        var dir: [UUID: MemberWithProfile] = [:]
        for m in members { dir[m.member.userId] = m }
        memberDirectory = dir

        // Inbox is cross-group; pending(_, groupId:) filters to this group
        // so unrelated rows from other groups don't leak into the section.
        // V1 attribution to a resource: `referenceId == resource.id` —
        // catches rsvpPending + fineProposalReview for events directly.
        // Phase 2 widens this to follow indirect refs (finePending →
        // fine → event, etc.).
        if let userId = app.session?.user.id,
           let allActions = try? await app.userActionRepo.pending(
               userId: userId,
               groupId: resource.groupId
           )
        {
            resourceActions = allActions.filter { $0.referenceId == resource.id }
        } else {
            resourceActions = []
        }
    }

    private var displayName: String {
        if case let .string(name) = resource.metadata["name"]  { return name }
        if case let .string(title) = resource.metadata["title"] { return title }
        return typeLabel
    }

    private var typeLabel: String {
        resource.resourceType.humanLabel
    }
}
