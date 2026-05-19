import SwiftUI
import RuulCore

public extension ResourceFamilyTint {
    var color: Color {
        switch self {
        case .events:     return .orange
        case .funds:      return .green
        case .votes:      return .blue
        case .fines:      return .red
        case .agreements: return .gray
        case .assets:     return .purple
        case .persons:    return .teal
        case .neutral:    return .secondary
        }
    }
}
