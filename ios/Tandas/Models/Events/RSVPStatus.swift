import Foundation

/// Member RSVP. Maps to `event_attendance.rsvp_status` with values:
///   .pending  → 'pending'
///   .going    → 'going'
///   .maybe    → 'maybe'
///   .declined → 'declined'   (UI label = "No voy")
enum RSVPStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending
    case going
    case maybe
    case declined

    var displayName: String {
        switch self {
        case .pending:  return "Sin responder"
        case .going:    return "Voy"
        case .maybe:    return "Tal vez"
        case .declined: return "No voy"
        }
    }
}
