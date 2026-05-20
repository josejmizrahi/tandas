import SwiftUI
import RuulCore
import RuulUI

struct RelationsRailView: View {
    let cards: [RelationCard]
    let onTap: (RelationCard) -> Void

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Relacionados")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RuulSpacing.sm) {
                        ForEach(cards) { card in
                            Button { onTap(card) } label: {
                                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                                    Image(systemName: card.icon)
                                        .foregroundStyle(card.tint.color)
                                    Text(card.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.primary)
                                    if let status = card.statusLine {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(Color.secondary)
                                    }
                                }
                                .padding(RuulSpacing.md)
                                .frame(width: 140, alignment: .leading)
                                .background(
                                    Color.ruulSurfaceSecondary,
                                    in: RoundedRectangle(cornerRadius: RuulRadius.md)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
