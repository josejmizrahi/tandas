import Foundation

public enum FrequencyType: String, Codable, Sendable, Hashable, CaseIterable {
    case weekly
    case biweekly
    case monthly
    case unscheduled

    public var displayName: String {
        switch self {
        case .weekly:      return "Semanal"
        case .biweekly:    return "Quincenal"
        case .monthly:     return "Mensual"
        case .unscheduled: return "Sin agenda fija"
        }
    }
}

public struct FrequencyConfig: Codable, Sendable, Hashable {
    public var dayOfWeek: Int?      // 0=Sunday..6=Saturday
    public var dayOfMonth: Int?     // 1..31
    public var hour: Int?           // 0..23
    public var minute: Int?         // 0..59

    public init(dayOfWeek: Int? = nil, dayOfMonth: Int? = nil, hour: Int? = nil, minute: Int? = nil) {
        self.dayOfWeek = dayOfWeek
        self.dayOfMonth = dayOfMonth
        self.hour = hour
        self.minute = minute
    }

    public static let empty = FrequencyConfig()

    public static func weekly(dayOfWeek: Int, hour: Int, minute: Int) -> FrequencyConfig {
        FrequencyConfig(dayOfWeek: dayOfWeek, dayOfMonth: nil, hour: hour, minute: minute)
    }
}
