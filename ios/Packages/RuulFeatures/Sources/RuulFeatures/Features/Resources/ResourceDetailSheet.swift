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
    @Environment(\.dismiss) private var dismiss

    public let resource: ResourceRow

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
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cerrar") { dismiss() }
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color.ruulBackground, for: .navigationBar)
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
                enabled: capabilities,
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
            resource: resource,
            group: group,
            currentUserId: app.session?.user.id,
            enabledCapabilities: enabledCapabilitySet,
            memberDirectory: memberDirectory,
            displayName: displayName,
            attentionActions: resourceActions,
            onPresentLedger: { ledgerSheetPresented = true },
            onPresentRules:  { rulesSheetPresented = true },
            onPresentEditResource:     { /* TODO Phase 2 */ },
            onPresentEnableCapability: { enableCapabilityPresented = true },
            onOpenInboxAction: { _ in /* TODO Phase 2 */ }
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
