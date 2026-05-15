import SwiftUI

public enum RuulCardStyle: Sendable, Hashable {
    /// Modern content tile — solid surface, no border, very subtle
    /// shadow. **Default** for content cards. Reads cleanly on the
    /// canvas background and over light ambient gradients.
    ///
    /// 2026-05-15 refresh: dropped the 0.5pt Apple-Sports border in
    /// favor of a Luma-style soft elevation so cards feel grounded
    /// without the picture-frame look.
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
        padding: CGFloat = RuulSpacing.lg,
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
        let shape = RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
        switch style {
        case .tile:
            // Modern tile: solid surface + very subtle shadow, no
            // border. Definition comes from elevation, not chrome.
            content
                .background(tint ?? Color.ruulSurface, in: shape)
                .ruulElevation(.sm)
        case .glass:
            content
                .ruulGlass(shape, material: .regular, tint: tint, interactive: interactive)
                .ruulElevation(.glass)
        case .solid:
            content
                .background(Color.ruulSurface, in: shape)
                .ruulElevation(.sm)
        case .outlined:
            content
                .overlay(shape.stroke(Color.ruulSeparatorOpaque, lineWidth: 1))
        }
    }
}

#if DEBUG
#Preview("RuulCard") {
    ScrollView {
        VStack(spacing: RuulSpacing.md) {
            RuulCard(.glass) {
                VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                    Text("Glass card")
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Default card style. Use over mesh backgrounds.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            RuulCard(.glass, tint: .ruulAccent) {
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
        .padding(RuulSpacing.lg)
    }
    .background(Color.ruulBackground)
}
#endif
