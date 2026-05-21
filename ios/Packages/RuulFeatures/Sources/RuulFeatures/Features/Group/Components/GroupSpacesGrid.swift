import SwiftUI
import RuulUI
import RuulCore

/// 2×2 grid of "spaces" matching the snippet's SpaceCard: icon in a
/// 32pt rounded square with linear gradient (tint→tint·0.7) + shadow,
/// radial-gradient decoration in the top-right corner of the card,
/// rounded mono primary stat, secondary text or red alert.
@MainActor
struct GroupSpacesGrid: View {
    struct Tile: Identifiable {
        let id: String
        let label: String
        let systemImage: String
        let tint: Color
        let primary: String
        let secondary: String
        let alert: String?
        let action: () -> Void
    }

    let tiles: [Tile]

    private let columns = [
        GridItem(.flexible(), spacing: RuulSpacing.sm + 2),
        GridItem(.flexible(), spacing: RuulSpacing.sm + 2)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Espacios")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)

            LazyVGrid(columns: columns, spacing: RuulSpacing.sm + 2) {
                ForEach(tiles) { tile in
                    Button(action: tile.action) { card(tile) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func card(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: tile.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ruulTextInverse)
                .frame(width: 32, height: 32)
                .background(
                    LinearGradient(
                        colors: [tile.tint, tile.tint.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                )
                .shadow(color: tile.tint.opacity(0.25), radius: 4, y: 2)
                .padding(.bottom, RuulSpacing.xl)

            Text(tile.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .padding(.bottom, 3)

            Text(tile.primary)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .kerning(-0.4)
                .monospacedDigit()
                .foregroundStyle(Color.primary)

            HStack(spacing: 4) {
                if let alert = tile.alert {
                    Text(alert)
                        .foregroundStyle(Color.ruulNegative)
                        .fontWeight(.semibold)
                } else {
                    Text(tile.secondary)
                        .foregroundStyle(Color.secondary)
                }
            }
            .font(.caption)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .padding(RuulSpacing.md + 2)
        .background {
            ZStack(alignment: .topTrailing) {
                Color.ruulSurface
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tile.tint.opacity(0.12), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .frame(width: 80, height: 80)
                    .offset(x: 20, y: -20)
            }
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
        }
        .contentShape(Rectangle())
    }
}
