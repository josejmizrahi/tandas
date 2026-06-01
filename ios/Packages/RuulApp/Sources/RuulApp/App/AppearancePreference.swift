import SwiftUI

/// User preference for app appearance. Persisted via `@AppStorage`
/// and applied at the shell root with `.preferredColorScheme(_:)`.
/// `.system` returns `nil` so the modifier becomes a no-op and the
/// OS decides — that is the canonical Apple-native pattern.
public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    public var systemImageName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    public static let storageKey = "appearance_preference"
}
