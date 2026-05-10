import Foundation

/// Append-only event log row. Anything that may trigger a Rule emits a
/// SystemEvent. The cron edge function `process-system-events` picks up
/// rows where `processedAt == nil` and runs matching rules.
///
/// `payload` is opaque — different `eventType`s carry different keys. The
/// rule engine destructures it inside each evaluator.
///
/// Conforms to `Atom` — `system_events` is the canonical append-only
/// log. History views in iOS are projections on top of it
/// (Plans/Active/AtomProjection.md).
public struct SystemEvent: Atom, Hashable {
    public static let atomTableName = "system_events"

    public let id: UUID
    public let groupId: UUID
    public let eventType: SystemEventType
    public let resourceId: UUID?
    public let memberId: UUID?
    public let payload: JSONConfig
    public let occurredAt: Date
    public let processedAt: Date?

    public init(
        id: UUID = UUID(),
        groupId: UUID,
        eventType: SystemEventType,
        resourceId: UUID? = nil,
        memberId: UUID? = nil,
        payload: JSONConfig = .empty,
        occurredAt: Date = .now,
        processedAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.eventType = eventType
        self.resourceId = resourceId
        self.memberId = memberId
        self.payload = payload
        self.occurredAt = occurredAt
        self.processedAt = processedAt
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case groupId      = "group_id"
        case eventType    = "event_type"
        case resourceId   = "resource_id"
        case memberId     = "member_id"
        case payload
        case occurredAt   = "occurred_at"
        case processedAt  = "processed_at"
    }
}
