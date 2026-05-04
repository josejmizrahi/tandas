import Foundation

/// `Rule.trigger` shape — pairs a SystemEventType with optional config.
///
/// `config` is loosely typed (Codable JSON envelope) because each event type
/// carries different keys. E.g. `hoursBeforeEvent` needs `{ "hours": 24 }`,
/// while `eventClosed` takes none.
public struct RuleTrigger: Sendable, Hashable, Codable {
    public let eventType: SystemEventType
    public let config: JSONConfig

    public init(eventType: SystemEventType, config: JSONConfig = .empty) {
        self.eventType = eventType
        self.config = config
    }

    enum CodingKeys: String, CodingKey {
        case eventType = "eventType"
        case config
    }
}
