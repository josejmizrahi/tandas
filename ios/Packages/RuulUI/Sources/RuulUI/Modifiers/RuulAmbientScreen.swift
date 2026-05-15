import SwiftUI

public extension View {
    /// Wrap any screen in a Luma-style ambient palette layer. The
    /// receiver renders inside a ZStack with `RuulAmbientBackground`
    /// behind it, ignoring safe-area so the tint extends edge-to-edge
    /// behind status bar and home indicator.
    ///
    /// The caller passes the palette — typically derived from a
    /// context the screen owns:
    ///
    /// - Resource detail   → cover palette (`ResourceAmbientPalette`)
    /// - Group-scoped tabs → active group's `category.ramp` stops
    /// - Profile / Settings → a neutral 3-stop derived from the user
    /// - Onboarding        → cover catalog default
    ///
    /// When `palette` is `nil`, the modifier is a no-op so callers can
    /// gate "show ambient only when there's an active context" without
    /// branching the view.
    ///
    /// Pair with `.ruulCardSurface(.glass)` on any cards inside the
    /// screen so they pick up the ambient tint instead of cutting it
    /// off with opaque chrome.
    func ruulAmbientScreen(
        palette: [Color]?,
        style: RuulAmbientBackground.Style = .soft
    ) -> some View {
        modifier(RuulAmbientScreenModifier(palette: palette, style: style))
    }
}

private struct RuulAmbientScreenModifier: ViewModifier {
    let palette: [Color]?
    let style: RuulAmbientBackground.Style

    func body(content: Content) -> some View {
        ZStack {
            // Canvas always sits at the bottom of the screen stack so
            // callers can pass `palette: nil` to opt out of the mesh
            // tint and still get a deterministic background. List /
            // dashboard screens (Home, Inbox, Activity, Profile)
            // typically want this — no cover anchor, so the ambient
            // mesh would read as "the screen is colored" rather than
            // "the entity wears a color".
            Color.ruulBackgroundCanvas.ignoresSafeArea()
            if let palette, !palette.isEmpty {
                RuulAmbientBackground(palette: palette, style: style)
            }
            content
        }
    }
}

#if DEBUG
#Preview("ruulAmbientScreen — group ramp") {
    let palette: [Color] = [.teal, .cyan, .blue, .indigo, .purple, .pink, .orange, .yellow, .green]
    return ScrollView {
        VStack(spacing: RuulSpacing.md) {
            ForEach(0..<6, id: \.self) { i in
                Text("Glass row \(i)")
                    .padding(RuulSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ruulCardSurface(.glass)
            }
        }
        .padding(RuulSpacing.lg)
    }
    .ruulAmbientScreen(palette: palette)
}
#endif
