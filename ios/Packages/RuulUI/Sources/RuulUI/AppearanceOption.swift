import SwiftUI
import RuulUI

public enum AppearanceOption: String, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "Auto"
        case .light:  "Claro"
        case .dark:   "Oscuro"
        }
    }

    public var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max"
        case .dark:   "moon"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}
