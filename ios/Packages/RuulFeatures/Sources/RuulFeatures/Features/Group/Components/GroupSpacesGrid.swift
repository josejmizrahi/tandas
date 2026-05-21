import SwiftUI
import RuulUI
import RuulCore

/// 2x2 grid of spaces inside the canonical section card chrome
/// (`Color.ruulSurface` + separator stroke + `RuulRadius.lg`). Each
/// tile = tinted icon + label + primary count + secondary line. No
/// gradients, no radial decoration — same chrome as every other
/// section card in the app, no hardcoded sizes/kerning.
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
        GridItem(.flexible(), spacing: RuulSpacing.sm),
        GridItem(.flexible(), spacing: RuulSpacing.sm)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Espacios")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)

            LazyVGrid(columns: columns, spacing: RuulSpacing.sm) {
                ForEach(tiles) { tile in
                    Button(action: tile.action) { card(tile) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func card(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Image(systemName: tile.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tile.tint)
                .frame(width: 32, height: 32)
                .background(tile.tint.opacity(0.12), in: Circle())

            Spacer(minLength: RuulSpacing.xs)

            Text(tile.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)

            Text(tile.primary)
                .font(.body.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let alert = tile.alert {
                Text(alert)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ruulNegative)
                    .lineLimit(1)
            } else {
                Text(tile.secondary)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}
