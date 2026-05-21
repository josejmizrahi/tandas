import SwiftUI
import RuulUI
import RuulCore

/// Compose chips inside the canonical section card (Color.ruulSurface
/// + separator stroke, RuulRadius.lg). Chips use the iOS 26 native
/// `.buttonStyle(.glass)` so they pick up Liquid Glass automatically.
@MainActor
struct GroupComposeBar: View {
    struct Chip: Identifiable {
        let id: String
        let label: String
        let systemImage: String
        let tint: Color
        let action: () -> Void
    }

    let chips: [Chip]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Coordinar")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.sm) {
                    ForEach(chips) { chip in
                        chipButton(chip)
                    }
                }
                .padding(RuulSpacing.md)
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
    }

    private func chipButton(_ chip: Chip) -> some View {
        Button(action: chip.action) {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: chip.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chip.tint)
                Text(chip.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
        }
        .buttonStyle(.glass)
        .sensoryFeedback(.selection, trigger: false)
    }
}
