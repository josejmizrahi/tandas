import SwiftUI

public enum RuulCardStyle: Sendable, Hashable {
    /// Apple Sports tile — solid elevated bg, 0.5pt subtle border, no shadow.
    /// **Default** for content cards. Quiet chrome that lets covers/scores
    /// take the visual lead.
    case tile
    /// Liquid Glass — reserved for transient surfaces (nav bars, sheets,
    /// floating overlays). Avoid on per-row content cards.
    case glass
    /// Solid background with elevation shadow. Use for hero/feature cards
    /// that need extra prominence (HomeView empty state, etc.).
    case solid
    /// Border-only, no fill. Use for ghost / placeholder states.
    case outlined
}

/// Card primitive. Variants control surface style.
public struct RuulCard<Content: View>: View {
    private let style: RuulCardStyle
    private let tint: Color?
    private let interactive: Bool
    private let padding: CGFloat
    private let content: () -> Content

    public init(
        _ style: RuulCardStyle = .tile,
        tint: Color? = nil,
        interactive: Bool = false,
        padding: CGFloat = RuulSpacing.s5,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.tint = tint
        self.interactive = interactive
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(RuulCardStyleModifier(style: style, tint: tint, interactive: interactive))
    }
}

private struct RuulCardStyleModifier: ViewModifier {
    let style: RuulCardStyle
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
        switch style {
        case .tile:
            // Apple Sports tile: solid + 0.5pt border, NO shadow.
            content
                .background(tint ?? Color.ruulBackgroundElevated, in: shape)
                .overlay(shape.stroke(Color.ruulBorderSubtle, lineWidth: 0.5))
        case .glass:
            content
                .ruulGlass(shape, material: .regular, tint: tint, interactive: interactive)
                .ruulElevation(.glass)
        case .solid:
            content
                .background(Color.ruulBackgroundElevated, in: shape)
                .ruulElevation(.sm)
        case .outlined:
            content
                .overlay(shape.stroke(Color.ruulBorderDefault, lineWidth: 1))
        }
    }
}

#if DEBUG
#Preview("RuulCard") {
    ScrollView {
        VStack(spacing: RuulSpacing.s4) {
            RuulCard(.glass) {
                VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                    Text("Glass card")
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Default card style. Use over mesh backgrounds.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            RuulCard(.glass, tint: .ruulAccentPrimary) {
                Text("Glass tinted")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            RuulCard(.solid) {
                Text("Solid card — for in-list usage on canvas backgrounds")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
            RuulCard(.outlined) {
                Text("Outlined card — minimal, no fill")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
            }
        }
        .padding(RuulSpacing.s5)
    }
    .background(Color.ruulBackgroundCanvas)
}
#endif
