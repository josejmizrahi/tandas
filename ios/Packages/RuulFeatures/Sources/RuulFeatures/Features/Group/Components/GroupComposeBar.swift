import SwiftUI
import RuulUI
import RuulCore

/// Compose chips wrapped in a warm-tinted card. Per the snippet:
/// serif italic question, horizontal scroll of glass chips, each chip
/// with a colored icon (per-action tint) + black label.
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
    /// Group's color ramp — drives the warm tint of the card wrapper.
    let ramp: GroupColorRamp

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("¿Qué quieres coordinar?")
                .font(.system(size: 15, design: .serif))
                .italic()
                .foregroundStyle(Color.primary)
                .padding(.horizontal, RuulSpacing.xxs)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.sm) {
                    ForEach(chips) { chip in
                        chipButton(chip)
                    }
                }
                .padding(.horizontal, RuulSpacing.xxs)
            }
            .padding(.horizontal, -RuulSpacing.xxs)
        }
        .padding(RuulSpacing.md)
        .background {
            ZStack {
                Color.ruulSurface
                LinearGradient(
                    colors: [ramp.accent.opacity(0.08), .clear, ramp.accent.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .strokeBorder(ramp.accent.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func chipButton(_ chip: Chip) -> some View {
        Button(action: chip.action) {
            HStack(spacing: RuulSpacing.xs) {
                Image(systemName: chip.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(chip.tint)
                Text(chip.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.xs + 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ruulGlass(Capsule(), material: .regular, interactive: true)
        .sensoryFeedback(.selection, trigger: false)
    }
}
