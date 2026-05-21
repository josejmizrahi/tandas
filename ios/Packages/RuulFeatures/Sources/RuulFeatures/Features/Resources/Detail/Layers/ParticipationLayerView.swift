import SwiftUI
import RuulCore
import RuulUI

/// Universal Resource Detail — **Participation layer**.
///
/// Answers the user's question: *¿Quién está involucrado y cómo?*
///
/// Same shape across resource types — event attendees, fund
/// contributors, asset custodians, trust beneficiaries, space members,
/// slot rotation, right holders. Today the visible content is event
/// RSVP + host rotation; future builders extend
/// `CapabilityBlock+Layer` with new participation IDs.
///
/// PR 3 of the layered rebuild parks the existing
/// `CapabilityBlockView` rendering inside this wrapper so the rest of
/// the codebase can refer to the layer by name. PR 4 introduces a
/// Coordination peer wrapper around the remaining capability blocks;
/// later PRs unify them under one universal block grammar.
///
/// Hides itself when `blocks` is empty so resources without
/// participation data (e.g. a placeholder fund) render no gap.
@MainActor
struct ParticipationLayerView: View {
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
