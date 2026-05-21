import SwiftUI
import RuulCore
import RuulUI

/// Universal Resource Detail — **Coordination layer**.
///
/// Answers the user's question: *¿Qué se está coordinando?*
///
/// Composed of the universal block grammar — `Money` / `Schedule` /
/// `Access` / `Responsibility` / `Rules` / `Usage`. A block reads
/// identically across resource types: a Money block in a fund, a fine,
/// and a trust distribution must look the same; an Access block in an
/// event location, a slot booking, and a right ticket must look the
/// same.
///
/// PR 4 introduces the layer wrapper and the per-block kind
/// classification (`CapabilityBlock.coordinationKind`). Each block
/// still renders through the existing `CapabilityBlockView`; a
/// follow-up PR swaps in the per-kind universal renderers
/// (`MoneyBlockView`, `ScheduleBlockView`, …) without touching the
/// host wiring.
///
/// Hides itself when `blocks` is empty so resources with no
/// coordination data (e.g. a brand-new right) render no gap.
@MainActor
struct CoordinationLayerView: View {
    let blocks: [CapabilityBlock]
    let tint: ResourceFamilyTint
    let onOpen: (String) -> Void

    var body: some View {
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                ForEach(blocks) { block in
                    CapabilityBlockView(
                        block: block,
                        tint: tint,
                        onOpen: {
                            if let destination = block.openDestinationId {
                                onOpen(destination)
                            }
                        }
                    )
                }
            }
        }
    }
}
