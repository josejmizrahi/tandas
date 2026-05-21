import SwiftUI
import RuulCore
import RuulUI

/// Universal detail surface. Renders a `ResourceBlocks` tree produced
/// upstream by a `BlockBuilder`. Contains ZERO branching on
/// `resource.resourceType` — every per-source decision was made in the
/// builder. Tabs/segmented control are gone. Single vertical scroll.
@MainActor
public struct UniversalResourceDetailView: View {
    public let blocks: ResourceBlocks
    public let supportedOverflowActions: Set<OverflowAction>
    /// Title surfaced in the navigation bar — used by `.ruulSheetToolbar`
    /// so every host inherits the canonical xmark close + centered
    /// title without duplicating chrome. Defaults to the identity title
    /// so callers don't have to thread it again.
    public let navigationTitle: String?
    /// Optional teardown hook for hosts that need to clear router state
    /// before SwiftUI's `\.dismiss` fires. nil → the standard dismiss
    /// behaviour is used.
    public let onClose: (() -> Void)?
    public let onPrimaryAction: () -> Void
    public let onOpenBlock: (String) -> Void
    public let onTapRelation: (RelationCard) -> Void
    public let onSeeMoreActivity: () -> Void
    public let onOverflowAction: (OverflowAction) -> Void

    public init(
        blocks: ResourceBlocks,
        supportedOverflowActions: Set<OverflowAction> = Set(OverflowAction.allCases),
        navigationTitle: String? = nil,
        onClose: (() -> Void)? = nil,
        onPrimaryAction: @escaping () -> Void,
        onOpenBlock: @escaping (String) -> Void,
        onTapRelation: @escaping (RelationCard) -> Void,
        onSeeMoreActivity: @escaping () -> Void,
        onOverflowAction: @escaping (OverflowAction) -> Void
    ) {
        self.blocks = blocks
        self.supportedOverflowActions = supportedOverflowActions
        self.navigationTitle = navigationTitle
        self.onClose = onClose
        self.onPrimaryAction = onPrimaryAction
        self.onOpenBlock = onOpenBlock
        self.onTapRelation = onTapRelation
        self.onSeeMoreActivity = onSeeMoreActivity
        self.onOverflowAction = onOverflowAction
    }

    /// Universal overflow actions. Hosts declare which subset they
    /// support via `supportedOverflowActions`; unsupported items are
    /// hidden so tapping never produces a silent no-op.
    public enum OverflowAction: String, Hashable, CaseIterable {
        case share, edit, archive, delete
        case addToCalendar, walletPass, report
    }

    public var body: some View {
        ScrollView {
            // Layered Universal Detail (PR 4 of N) — Identity / Context /
            // Participation / Coordination / Activity. See
            // `Plans/Active/Fase1ComponentMap.md` §"Universal Resource
            // Detail — layered architecture". Coordination still renders
            // through the existing `CapabilityBlockView` per block until
            // the universal-block primitives ship in a follow-up PR.
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                IdentityLayerView(
                    identity: blocks.identity,
                    state: blocks.state,
                    onPrimaryTap: onPrimaryAction
                )
                ContextLayerView(
                    properties: blocks.properties,
                    relations: blocks.relations,
                    onTapRelation: onTapRelation
                )
                ParticipationLayerView(
                    blocks: participationBlocks,
                    tint: blocks.identity.tint,
                    onOpen: onOpenBlock
                )
                CoordinationLayerView(
                    blocks: coordinationBlocks,
                    tint: blocks.identity.tint,
                    onOpen: onOpenBlock
                )
                ActivityLayerView(
                    entries: blocks.activityHead,
                    hasMore: blocks.hasMoreActivity,
                    onSeeMore: onSeeMoreActivity
                )
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.ruulBackground.ignoresSafeArea())
        // Toolbar chrome (xmark close + centered title) is the host's
        // responsibility — we don't apply `.ruulSheetToolbar(...)` here
        // to avoid stacking it with the outer wrapper's toolbar (which
        // would surface two leading-x buttons on the same nav bar).
        .toolbar {
            // Action layer per doctrine: `[+]` compose menu + `[⚙]`
            // settings split (replaces the previous single
            // `ellipsis.circle` overflow). See
            // `Plans/Active/Fase1ComponentMap.md` §"Universal Resource
            // Detail — Action layer".
            if !composeActions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        composeMenuContents
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Acciones")
                }
            }
            if !settingsActions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        settingsMenuContents
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Ajustes")
                }
            }
        }
    }

    // MARK: - Layer partition (PR 3)

    /// Capability blocks sorted by the canonical priority resolver,
    /// then partitioned into the Participation layer (`rsvp`, `rotation`,
    /// future members/custodians/beneficiaries) and the residual
    /// Coordination subset that PR 4 will lift into its own layer.
    private var orderedCapabilities: [CapabilityBlock] {
        BlockPriorityResolver.order(blocks.capabilities)
    }

    private var participationBlocks: [CapabilityBlock] {
        orderedCapabilities.filter(\.belongsToParticipationLayer)
    }

    private var coordinationBlocks: [CapabilityBlock] {
        orderedCapabilities.filter { !$0.belongsToParticipationLayer }
    }

    // MARK: - Action layer (PR 8 — toolbar [+] compose + [⚙] settings)

    /// Compose actions per doctrine — outward-facing verbs that grow
    /// the resource (share/invite, add to calendar). Future PRs add
    /// inline composers (Invitar gente, Agregar gasto, Asignar
    /// custodia, Agregar regla) here.
    private var composeActions: Set<OverflowAction> {
        supportedOverflowActions.intersection([.share, .addToCalendar])
    }

    /// Settings actions per doctrine — configuration and meta only,
    /// never primary actions. Includes the destructive cluster.
    private var settingsActions: Set<OverflowAction> {
        supportedOverflowActions.intersection([
            .edit, .walletPass, .archive, .delete, .report
        ])
    }

    /// `[+]` menu contents. Sentence case, verb+noun labels.
    @ViewBuilder
    private var composeMenuContents: some View {
        if supportedOverflowActions.contains(.share) {
            Button("Compartir", systemImage: "square.and.arrow.up") { onOverflowAction(.share) }
        }
        if supportedOverflowActions.contains(.addToCalendar) {
            Button("Agregar al calendario", systemImage: "calendar.badge.plus") {
                onOverflowAction(.addToCalendar)
            }
        }
    }

    /// `[⚙]` menu contents. Configuration + meta. Destructive cluster
    /// trails behind a divider (only when both clusters are populated)
    /// — mirrors Apple Settings sheet ordering.
    @ViewBuilder
    private var settingsMenuContents: some View {
        if supportedOverflowActions.contains(.edit) {
            Button("Editar", systemImage: "pencil") { onOverflowAction(.edit) }
        }
        if supportedOverflowActions.contains(.walletPass) {
            Button("Pase de Wallet", systemImage: "wallet.pass") { onOverflowAction(.walletPass) }
        }
        if hasSettingsNondestructive && hasSettingsDestructive {
            Divider()
        }
        if supportedOverflowActions.contains(.archive) {
            Button("Archivar", systemImage: "archivebox") { onOverflowAction(.archive) }
        }
        if supportedOverflowActions.contains(.delete) {
            Button("Eliminar", systemImage: "trash", role: .destructive) { onOverflowAction(.delete) }
        }
        if supportedOverflowActions.contains(.report) {
            Button("Reportar", systemImage: "flag") { onOverflowAction(.report) }
        }
    }

    private var hasSettingsNondestructive: Bool {
        supportedOverflowActions.contains(.edit)
            || supportedOverflowActions.contains(.walletPass)
    }

    private var hasSettingsDestructive: Bool {
        supportedOverflowActions.contains(.archive)
            || supportedOverflowActions.contains(.delete)
            || supportedOverflowActions.contains(.report)
    }
}
