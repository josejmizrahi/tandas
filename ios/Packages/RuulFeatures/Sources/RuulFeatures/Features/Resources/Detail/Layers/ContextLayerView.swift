import SwiftUI
import RuulCore
import RuulUI

/// Universal Resource Detail — **Context layer**.
///
/// Answers the user's question: *¿Por qué existe esto?*
///
/// In PR 2 this layer holds two existing primitives that already speak
/// to "context":
///   - `PropertiesBlockView` — the 4-7 key/value facts the builder
///     emits (Cuándo / Dónde / Anfitrión for an event; Saldo /
///     Cuándo cierra for a fund; …).
///   - `RelationsRailView` — the horizontal rail of linked resources
///     (parent series, related event, etc.).
///
/// Both child views already self-hide when their payload is empty, so
/// this wrapper renders nothing when the resource has no context to
/// show — matching the doctrine rule "the Context layer is visible
/// when there's a non-trivial description, purpose, or link to other
/// resources."
///
/// Subsequent PRs will fold a free-text description here when the
/// builders expose one, and may move properties out into Identity or
/// the relevant Coordination block; the wrapper shape is the stable
/// referent.
@MainActor
struct ContextLayerView: View {
    let properties: PropertiesBlock
    let relations: [RelationCard]
    let onTapRelation: (RelationCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.lg) {
            PropertiesBlockView(block: properties)
            RelationsRailView(cards: relations, onTap: onTapRelation)
        }
    }
}
