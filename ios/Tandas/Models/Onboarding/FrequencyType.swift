import Foundation

enum FrequencyType: String, Codable, Sendable, Hashable, CaseIterable {
    case weekly
    case biweekly
    case monthly
    case unscheduled

    var displayName: String {
        switch self {
        case .weekly:      return "Semanal"
        case .biweekly:    return "Quincenal"
        case .monthly:     return "Mensual"
        case .unscheduled: return "Sin agenda fija"
        }
    }
}

struct FrequencyConfig: Codable, Sendable, Hashable {
    var dayOfWeek: Int?      // 0=Sunday..6=Saturday
    var dayOfMonth: Int?     // 1..31
    var hour: Int?           // 0..23
    var minute: Int?         // 0..59

    static let empty = FrequencyConfig()

    static func weekly(dayOfWeek: Int, hour: Int, minute: Int) -> FrequencyConfig {
        FrequencyConfig(dayOfWeek: dayOfWeek, dayOfMonth: nil, hour: hour, minute: minute)
    }
}
