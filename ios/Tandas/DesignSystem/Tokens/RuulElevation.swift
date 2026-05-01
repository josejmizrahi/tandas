import SwiftUI

/// Elevation tokens. Apply via `.ruulElevation(.md)` modifier on any view.
///
/// Semantic guidelines:
/// - Cards in list: `.sm`
/// - Active / selected card: `.md`
/// - Floating CTAs, modal sheets: `.lg`
/// - Any glass surface: `.glass`
public enum RuulElevation: Sendable {
    case none
    case sm
    case md
    case lg
    case glass
}

public extension View {
    func ruulElevation(_ level: RuulElevation) -> some View {
        modifier(RuulElevationModifier(level: level))
    }
}

private struct RuulElevationModifier: ViewModifier {
    let level: RuulElevation

    func body(content: Content) -> some View {
        switch level {
        case .none:
            content
        case .sm:
            content.shadow(color: .ruulShadow(.sm), radius: 1.5, x: 0, y: 1)
        case .md:
            content.shadow(color: .ruulShadow(.md), radius: 6, x: 0, y: 4)
        case .lg:
            content.shadow(color: .ruulShadow(.lg), radius: 16, x: 0, y: 12)
        case .glass:
            content
                .shadow(color: .ruulShadow(.md), radius: 8, x: 0, y: 6)
                .shadow(color: .ruulShadow(.sm), radius: 1, x: 0, y: 1)
        }
    }
}

private extension Color {
    /// Shadow tint per level. Pulled from RuulColors so dark mode gets darker
    /// shadows (more contrast against dark surfaces).
    static func ruulShadow(_ level: ShadowLevel) -> Color {
        switch level {
        case .sm: return RuulColors.default.shadowSm
        case .md: return RuulColors.default.shadowMd
        case .lg: return RuulColors.default.shadowLg
        }
    }
}

private enum ShadowLevel { case sm, md, lg }
