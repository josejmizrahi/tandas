import SwiftUI
import RuulUI
import RuulCore

/// Fallback body for vote types without dedicated UI yet. Renders the
/// vote's description in plain Spanish; if there's no description,
/// shows a neutral placeholder. The raw JSON payload card was removed
/// in Beta 1 W2-C1 — the user never wants to see "PAYLOAD" + JSON in
/// the inbox; that was developer-facing debugging that leaked into prod.
public struct GenericVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            if let desc = coordinator.vote.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            } else {
                Text("Sin detalles adicionales.")
                    .font(.subheadline)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
    }
}
