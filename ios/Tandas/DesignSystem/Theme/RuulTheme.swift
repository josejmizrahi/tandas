import SwiftUI

/// Bundle of resolved design-system values keyed by the current scheme +
/// contrast environment. Use sparingly — most callers should access tokens
/// directly via `Color.ruul*` / `Font.ruul*`. The theme exists for views that
/// need to react to scheme changes mid-render (e.g. switching the showcase
/// preview between light/dark/HC at runtime).
public struct RuulTheme: Sendable {
    public let colors: RuulColors

    public init(colors: RuulColors = .default) {
        self.colors = colors
    }
}

public extension EnvironmentValues {
    @Entry var ruulTheme: RuulTheme = RuulTheme()
}

public extension EnvironmentValues {
    /// Convenience: pulls `colors` out of the theme so call sites can write
    /// `@Environment(\.ruulColors)` instead of `\.ruulTheme.colors`.
    var ruulColors: RuulColors {
        ruulTheme.colors
    }
}

public extension View {
    /// Install the default ruul theme into the environment. Apply once at the
    /// app root.
    func ruulTheme(_ theme: RuulTheme = RuulTheme()) -> some View {
        environment(\.ruulTheme, theme)
    }
}
