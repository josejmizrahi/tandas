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
/// V1 leaves ledger / rules sub-sheet presentation as no-ops because
/// the existing sheets are still event-shaped (they take `Event`, not
/// `ResourceRow`). The sections still render and route the user toward
/// the action — they just don't open a follow-up sheet yet. Phase 2
/// generalizes `EventLedgerCoordinator` / `EventRulesCoordinator` to
/// `ResourceLedgerCoordinator` / `ResourceRulesCoordinator` and wires
/// them in here.
public struct ResourceDetailSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let resource: ResourceRow

    @State private var capabilities: [ResourceCapability] = []
    @State private var memberDirectory: [UUID: MemberWithProfile] = [:]

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
    }

    @ViewBuilder
    private var content: some View {
        if let group = parentGroup {
            UniversalResourceDetailView(context: context(for: group))
        } else {
            ZStack {
                Color.ruulBackground.ignoresSafeArea()
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
            attentionActions: [],
            onPresentLedger: { /* TODO Phase 2: polymorphic ledger sheet */ },
            onPresentRules:  { /* TODO Phase 2: polymorphic rules sheet */ },
            onPresentEditResource:     { /* TODO Phase 2 */ },
            onPresentEnableCapability: { /* TODO Phase 2 */ },
            onOpenInboxAction: { _ in /* TODO Phase 2 */ }
        )
    }

    private var enabledCapabilitySet: Set<String> {
        Set(capabilities.filter { $0.enabled }.map { $0.capabilityBlockId })
    }

    @MainActor
    private func load() async {
        async let capsTask = app.resourceCapabilityRepo.list(resourceId: resource.id)
        async let membersTask = app.groupsRepo.membersWithProfiles(of: resource.groupId)
        capabilities = (try? await capsTask) ?? []
        let members = (try? await membersTask) ?? []
        var dir: [UUID: MemberWithProfile] = [:]
        for m in members { dir[m.member.userId] = m }
        memberDirectory = dir
    }

    private var displayName: String {
        if case let .string(name) = resource.metadata["name"]  { return name }
        if case let .string(title) = resource.metadata["title"] { return title }
        return typeLabel
    }

    private var typeLabel: String {
        switch resource.resourceType {
        case .event:        return "Evento"
        case .asset:        return "Activo"
        case .slot:         return "Slot"
        case .fund:         return "Fondo"
        case .booking:      return "Reserva"
        case .contribution: return "Aportación"
        case .position:     return "Posición"
        case .assignment:   return "Tarea"
        case .rotation:     return "Rotación"
        case .guestPass:    return "Invitado"
        case .proposal:     return "Propuesta"
        case .unknown(let raw): return raw
        }
    }
}
