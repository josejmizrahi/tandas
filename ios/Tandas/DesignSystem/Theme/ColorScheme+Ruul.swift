import SwiftUI

/// Helpers around `ColorScheme` and accessibility contrast.
public extension ColorScheme {
    var isDark: Bool { self == .dark }
}

/// Aggregate enum used by the showcase to override scheme + contrast in one shot.
///
/// **Note**: SwiftUI doesn't expose a public way to write to
/// `\.colorSchemeContrast`, so the high-contrast variants here only flip the
/// scheme. To preview true high-contrast behavior, enable
/// Settings → Accessibility → Display & Text Size → Increase Contrast on the
/// simulator. The showcase displays a banner noting this.
public enum RuulSchemeOverride: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case lightHighContrast
    case darkHighContrast

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .light:             return "Light"
        case .dark:              return "Dark"
        case .lightHighContrast: return "Light HC*"
        case .darkHighContrast:  return "Dark HC*"
        }
    }

    public var colorScheme: ColorScheme {
        switch self {
        case .light, .lightHighContrast: return .light
        case .dark, .darkHighContrast:   return .dark
        }
    }

    public var requiresHighContrast: Bool {
        switch self {
        case .lightHighContrast, .darkHighContrast: return true
        default: return false
        }
    }
}

public extension View {
    /// Force a color scheme in the environment. Used by the showcase.
    func ruulSchemeOverride(_ override: RuulSchemeOverride) -> some View {
        self.environment(\.colorScheme, override.colorScheme)
    }
}
