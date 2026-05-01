import Foundation

/// User choice in `RecurrenceOptionsCard` (only shown for the first event
/// in a group with frequency configured).
enum RecurrenceOption: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case onlyThis        // create only this event
    case nextFour        // create this + next 3 (4 total)
    case untilCancelled  // create this + set groups.auto_generate_events=true

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onlyThis:       return "Solo este por ahora"
        case .nextFour:       return "Sí, los siguientes 4 eventos"
        case .untilCancelled: return "Sí, todos hasta que cancele"
        }
    }
}
