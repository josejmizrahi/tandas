import Foundation

/// Makes `Event` a first-class `Resource`. Simple bridge: forward
/// the typed `EventStatus` to `resourceStatus: String` via rawValue
/// and declare `resourceType` constant.
///
/// `Event.status: EventStatus` (stored, typed) stays the primary API
/// for event-specific code paths. `Event.resourceStatus: String` is
/// the polymorphic bridge for callers holding `any Resource`.
extension Event: Resource {
    public var resourceType: ResourceType { .event }
    public var resourceStatus: String { status.rawValue }
}
