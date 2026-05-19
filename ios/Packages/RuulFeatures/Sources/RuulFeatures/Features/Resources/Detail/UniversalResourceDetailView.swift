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
    public let onPrimaryAction: () -> Void
    public let onOpenBlock: (String) -> Void
    public let onTapRelation: (RelationCard) -> Void
    public let onSeeMoreActivity: () -> Void
    public let onOverflowAction: (OverflowAction) -> Void

    public init(
        blocks: ResourceBlocks,
        onPrimaryAction: @escaping () -> Void,
        onOpenBlock: @escaping (String) -> Void,
        onTapRelation: @escaping (RelationCard) -> Void,
        onSeeMoreActivity: @escaping () -> Void,
        onOverflowAction: @escaping (OverflowAction) -> Void
    ) {
        self.blocks = blocks
        self.onPrimaryAction = onPrimaryAction
        self.onOpenBlock = onOpenBlock
        self.onTapRelation = onTapRelation
        self.onSeeMoreActivity = onSeeMoreActivity
        self.onOverflowAction = onOverflowAction
    }

    public enum OverflowAction: Hashable {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Compartir", systemImage: "square.and.arrow.up") { onOverflowAction(.share) }
                    Button("Editar",    systemImage: "pencil")               { onOverflowAction(.edit) }
                    Button("Agregar al calendario", systemImage: "calendar.badge.plus") { onOverflowAction(.addToCalendar) }
                    Button("Pase de Wallet", systemImage: "wallet.pass")     { onOverflowAction(.walletPass) }
                    Divider()
                    Button("Archivar",  systemImage: "archivebox")           { onOverflowAction(.archive) }
                    Button("Eliminar",  systemImage: "trash", role: .destructive) { onOverflowAction(.delete) }
                    Button("Reportar",  systemImage: "flag")                 { onOverflowAction(.report) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
