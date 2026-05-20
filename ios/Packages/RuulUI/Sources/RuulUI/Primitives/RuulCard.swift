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
            // Luma-style glass tile: translucent material that picks up
            // the ambient palette of the parent screen. When a tint is
            // supplied (e.g. categorical card variant), it layers on top
            // of the material for a subtly colored glass.
            if let tint {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .background(tint.opacity(0.20), in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
            }
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
                .overlay(shape.stroke(Color(.separator), lineWidth: 1))
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
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text("Default card style. Use over mesh backgrounds.")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }
            RuulCard(.glass, tint: .ruulAccent) {
                Text("Glass tinted")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
            RuulCard(.solid) {
                Text("Solid card — for in-list usage on canvas backgrounds")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
            }
            RuulCard(.outlined) {
                Text("Outlined card — minimal, no fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
            }
        }
        .padding(RuulSpacing.lg)
    }
    .background(Color.ruulBackground)
}
#endif
