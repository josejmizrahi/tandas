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

    public init(resource: ResourceRow) { self.resource = resource }

    public var body: some View {
        NavigationStack {
            content
                .ruulSheetToolbar(displayName, onClose: { dismiss() })
        }
        .task { await load() }
        .task { await redirectIfEvent() }
        .sheet(isPresented: $ledgerSheetPresented) {
            if let ledgerCoordinator {
                ResourceLedgerSheet(
                    isPresented: $ledgerSheetPresented,
                    coordinator: ledgerCoordinator,
                    groupVocabulary: typeLabel.lowercased()
                )
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial.opacity(0.5))
            }
        }
        .onChange(of: ledgerSheetPresented) { _, presented in
            if presented && ledgerCoordinator == nil {
                ledgerCoordinator = makeLedgerCoordinator()
            }
        }
        .sheet(isPresented: $rulesSheetPresented) {
            if let rulesCoordinator {
                ResourceRulesSheet(
                    isPresented: $rulesSheetPresented,
                    coordinator: rulesCoordinator
                )
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial.opacity(0.5))
            }
        }
        .onChange(of: rulesSheetPresented) { _, presented in
            if presented && rulesCoordinator == nil {
                rulesCoordinator = makeRulesCoordinator()
            }
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
            // Phase E: rebuild block tree with the fresh row
            if let group = parentGroup {
                await buildBlocks(for: group)
            }
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
        case .slotPending, .contributionDue, .compensationDue, .assetActionApproval:
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

    // MARK: - Phase E: block-tree rendering

    /// Block-tree state — recomputed after load and after any resource mutation.
    @State private var blocks: ResourceBlocks?

    @ViewBuilder
    private var content: some View {
        if let group = parentGroup {
            if let blocks {
                UniversalResourceDetailView(
                    blocks: blocks,
                    supportedOverflowActions: supportedOverflowActions(for: blocks),
                    navigationTitle: displayName,
                    onClose: { dismiss() },
                    onPrimaryAction: { Task { await dispatchPrimary(group: group) } },
                    onOpenBlock: { id in openBlockDestination(id, group: group) },
                    onTapRelation: { _ in },
                    onSeeMoreActivity: { /* TODO: dedicated activity history sheet */ },
                    onOverflowAction: { handleOverflow($0) }
                )
            } else {
                ZStack {
                    Color.ruulBackgroundCanvas.ignoresSafeArea()
                    RuulLoadingState()
                }
                .task { await buildBlocks(for: group) }
            }
        } else {
            ZStack {
                Color.ruulBackgroundCanvas.ignoresSafeArea()
                RuulLoadingState()
            }
        }
    }

    /// Per-resource-type overflow allowlist. Today every non-event row
    /// reachable through this sheet supports just Share (the universal
    /// action that every resource family carries). Type-specific
    /// surfaces — fund settlement, asset transfer, right revoke — live
    /// in their dedicated sheets, not the universal overflow.
    private func supportedOverflowActions(
        for blocks: ResourceBlocks
    ) -> Set<UniversalResourceDetailView.OverflowAction> {
        // Events that somehow reach this generic sheet trigger the
        // redirect-to-EventDetailHost task; while the redirect is in
        // flight, show no overflow.
        if (liveResource ?? resource).resourceType == .event { return [] }
        return [.share]
    }

    /// Builds blocks from the current resource row + group, then augments
    /// the result with the live activity feed.
    ///
    /// Events do NOT build blocks here — the body short-circuits to a
    /// router redirect (see `redirectIfEvent`). Reaching this method with
    /// an event row means the redirect path didn't fire; we fall back to
    /// an identity-only placeholder rather than mis-rendering the event
    /// through a non-event builder.
    @MainActor
    private func buildBlocks(for group: RuulCore.Group) async {
        let live = liveResource ?? resource
        let viewerCtx = viewerContext(group: group)
        let built: ResourceBlocks
        switch live.resourceType {
        case .event:
            built = neutralEventPlaceholderBlocks(for: live)
        case .fund:
            built = FundBlockBuilder().build(source: live, viewer: viewerCtx, now: Date())
        case .right:
            built = RightBlockBuilder().build(source: live, viewer: viewerCtx, now: Date())
        case .asset, .space, .slot:
            built = AssetBlockBuilder().build(source: live, viewer: viewerCtx, now: Date())
        case .unknown:
            built = AssetBlockBuilder().build(source: live, viewer: viewerCtx, now: Date())
        }

        // Post-build augmentation: load system_events for this resource
        // so the activity layer reflects creation/mutation/lifecycle
        // events. Events skip the feed since they redirect anyway.
        if live.resourceType == .event {
            blocks = built
        } else {
            let feed = await ActivityFeedLoader.load(
                app: app,
                groupId: live.groupId,
                resourceId: live.id
            )
            blocks = ResourceBlocks(
                identity: built.identity,
                state: built.state,
                properties: built.properties,
                capabilities: built.capabilities,
                relations: built.relations,
                activityHead: feed.entries,
                hasMoreActivity: feed.hasMore
            )
        }
    }

    /// Identity-only placeholder for events that somehow reach this
    /// generic sheet instead of `EventDetailHost`. The state hero tells
    /// the user we're routing to the right surface; `redirectIfEvent`
    /// does the actual dismiss + push.
    private func neutralEventPlaceholderBlocks(for live: ResourceRow) -> ResourceBlocks {
        let title = live.metadata["title"]?.stringValue ?? "Evento"
        return ResourceBlocks(
            identity: IdentityRibbon(
                icon: "calendar", tint: .events,
                title: title, subtitleSegments: ["Evento"]
            ),
            state: StateHeadline(
                headline: "Abriendo el evento…",
                supportingFacts: [],
                primaryAction: nil,
                urgency: .ambient
            ),
            properties: PropertiesBlock(rows: []),
            capabilities: [],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }

    /// Fires once on appear when the resource is an event: fetches the
    /// full Event and hands off to `router.openEvent`, dismissing this
    /// generic sheet. The placeholder blocks above keep the screen
    /// neutral while the fetch resolves.
    @MainActor
    private func redirectIfEvent() async {
        guard resource.resourceType == .event else { return }
        guard let event = try? await app.eventRepo.event(resource.id) else {
            // No event row found — leave the placeholder in place and
            // let the user dismiss. Silently swallowing the error here
            // mirrors the legacy behaviour for missing event rows.
            return
        }
        router.openEvent(event)
        dismiss()
    }

    private func viewerContext(group: RuulCore.Group) -> BlockViewerContext {
        let userId = app.session?.user.id
        let me = userId.flatMap { memberDirectory[$0] }?.member
        let catalog = group.effectiveRoles
        var perms = Set<Permission>()
        if let me {
            for raw in me.rawRoles {
                if let def = catalog[raw] {
                    for p in def.permissions { perms.insert(p) }
                }
            }
        }
        return BlockViewerContext(
            userId: userId,
            permissions: perms,
            activeModules: Set(group.effectiveActiveModules),
            memberId: me?.id
        )
    }

    @MainActor
    private func dispatchPrimary(group: RuulCore.Group) async {
        guard let kind = blocks?.state.primaryAction?.kind else { return }
        switch kind {
        case .openContribute:
            ledgerSheetPresented = true  // route to ledger for fund contribute
        case .openBooking:
            break  // slot/space booking — post-Beta-1
        case .exerciseRight:
            break  // right exercise — post-Beta-1
        case .rsvpConfirm, .rsvpCancel, .viewHostActions,
             .viewClosed, .payFine, .castVote:
            break  // not applicable for non-event resources in this path
        case .none:
            break  // PrimaryAction.Kind.none — no CTA
        }
    }

    private func openBlockDestination(_ id: String, group: RuulCore.Group) {
        switch id {
        case "fund.ledger":
            ledgerSheetPresented = true
        case "fund.contribute":
            ledgerSheetPresented = true  // routes to ledger where contributions are shown
        case "rules":
            rulesSheetPresented = true
        default:
            break
        }
    }

    private func handleOverflow(_ action: UniversalResourceDetailView.OverflowAction) {
        switch action {
        case .share:
            break  // post-Beta-1
        case .edit:
            break  // no editor for fund/asset in this path yet
        case .addToCalendar, .walletPass:
            break  // not applicable
        case .archive:
            break  // post-Beta-1
        case .delete, .report:
            break
        }
    }

    private var parentGroup: RuulCore.Group? {
        app.groups.first(where: { $0.id == resource.groupId })
    }

    // Phase E: context(for:) and enabledCapabilitySet removed —
    // ResourceDetailSheet now builds ResourceBlocks directly via builders.
    // The capabilities set is retained for ledger/rules coordinator creation
    // but no longer drives section gating inside the View.

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
            canCreate: canCreateRules
        )
        return ResourceRulesCoordinator(
            context: ctx,
            ruleRepo: app.ruleRepo,
            shapeRegistry: app.ruleShapeRegistry
        )
    }

    /// True when the current user holds a role with the `modifyRules`
    /// permission. Local catalog walk (server still gates the write at
    /// the RPC level via has_permission(modifyRules)).
    ///
    /// Sprint E (V18 fix): pre-Sprint-E this gated on identity (`group
    /// .createdBy == userId`) which meant a transferred-founder or a
    /// custom rules-managing role couldn't see the create-rule CTA.
    /// Now reads the catalog so any role with `modifyRules` qualifies.
    private var canCreateRules: Bool {
        guard let userId = app.session?.user.id,
              let group = parentGroup,
              let me = memberDirectory[userId]?.member else { return false }
        let catalog = group.effectiveRoles
        for raw in me.rawRoles {
            if let def = catalog[raw], def.grants(.modifyRules) { return true }
        }
        return false
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

        // Phase E: build the initial block tree now that we have member directory.
        if let group = parentGroup {
            await buildBlocks(for: group)
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
