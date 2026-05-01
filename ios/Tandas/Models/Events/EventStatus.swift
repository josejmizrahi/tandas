import Foundation

/// Lifecycle state of an event. Maps to the existing Postgres
/// `events.status` text column with values:
///   .upcoming    → 'scheduled'
///   .inProgress  → 'in_progress'
///   .closed      → 'completed'
///   .cancelled   → 'cancelled'
enum EventStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case upcoming    = "scheduled"
    case inProgress  = "in_progress"
    case closed      = "completed"
    case cancelled

    var displayName: String {
        switch self {
        case .upcoming:   return "Próximo"
        case .inProgress: return "Pasando ahora"
        case .closed:     return "Cerrado"
        case .cancelled:  return "Cancelado"
        }
    }

    var isActive: Bool {
        self == .upcoming || self == .inProgress
    }
}
