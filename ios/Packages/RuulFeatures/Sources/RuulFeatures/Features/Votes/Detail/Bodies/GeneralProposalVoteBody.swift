import SwiftUI
import RuulUI
import RuulCore

/// Body para `VoteType.generalProposal`. Renderiza el description
/// del vote como cuerpo principal del proposal. Sin payload structurado
/// adicional — los proposals son textuales en V1.
public struct GeneralProposalVoteBody: View {
    @Bindable var coordinator: VoteDetailCoordinator

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            if let desc = coordinator.vote.description, !desc.isEmpty {
                Text(desc)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("(Sin descripción)")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextTertiary)
            }

            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
                Text("Cierra \(coordinator.vote.closesAt.ruulRelativeDescription)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
        }
    }
}
