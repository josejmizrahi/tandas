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
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                IdentityRibbonView(ribbon: blocks.identity)
                StateHeroView(
                    headline: blocks.state,
                    tint: blocks.identity.tint,
                    onPrimaryTap: onPrimaryAction
                )
                PropertiesBlockView(block: blocks.properties)
                ForEach(BlockPriorityResolver.order(blocks.capabilities)) { block in
                    CapabilityBlockView(
                        block: block,
                        tint: blocks.identity.tint,
                        onOpen: {
                            if let id = block.openDestinationId {
                                onOpenBlock(id)
                            }
                        }
                    )
                }
                RelationsRailView(cards: blocks.relations, onTap: onTapRelation)
                ActivityFeedView(
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
        // Canonical sheet chrome: xmark close on leading, title centered.
        // Reuses the same .ruulSheetToolbar every other modal in the app
        // uses, so the dismiss affordance is consistent. Hosts that need
        // a custom dismiss path pass `onClose`; the default is SwiftUI's
        // `\.dismiss` from the environment.
        .ruulSheetToolbar(navigationTitle ?? blocks.identity.title, onClose: onClose)
        .toolbar {
            if !supportedOverflowActions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        overflowMenuContents
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    /// Renders only the overflow items the host opted in to, so tapping
    /// never produces a silent no-op. Per doctrine §0: the overflow is
    /// for meta-actions only — capabilities live in their own blocks.
    @ViewBuilder
    private var overflowMenuContents: some View {
        if supportedOverflowActions.contains(.share) {
            Button("Compartir", systemImage: "square.and.arrow.up") { onOverflowAction(.share) }
        }
        if supportedOverflowActions.contains(.edit) {
            Button("Editar", systemImage: "pencil") { onOverflowAction(.edit) }
        }
        if supportedOverflowActions.contains(.addToCalendar) {
            Button("Agregar al calendario", systemImage: "calendar.badge.plus") {
                onOverflowAction(.addToCalendar)
            }
        }
        if supportedOverflowActions.contains(.walletPass) {
            Button("Pase de Wallet", systemImage: "wallet.pass") { onOverflowAction(.walletPass) }
        }
        // Divider only between the "viewing/editing" cluster and the
        // destructive cluster, and only when both clusters have at least
        // one supported action.
        if hasNondestructiveSupported && hasDestructiveSupported {
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

    private var hasNondestructiveSupported: Bool {
        supportedOverflowActions.contains(.share)
            || supportedOverflowActions.contains(.edit)
            || supportedOverflowActions.contains(.addToCalendar)
            || supportedOverflowActions.contains(.walletPass)
    }

    private var hasDestructiveSupported: Bool {
        supportedOverflowActions.contains(.archive)
            || supportedOverflowActions.contains(.delete)
            || supportedOverflowActions.contains(.report)
    }
}
