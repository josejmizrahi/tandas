import Foundation

/// Primitiva 13 (Memoria). Mirrors `public.group_events` 1:1 via the
/// `group_events_recent(...)` read RPC. Each row is an append-only
/// fact about something the group did or that happened to it.
/// `event_type` is open text (every RPC adds its own dotted key), so
/// we keep the model flexible — the iOS layer recognises a curated
/// subset for icon/copy mapping and falls back to a neutral default
/// for anything else.
public struct GroupEvent: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID                       // event_uuid
    public let groupId: UUID
    public let actorUserId: UUID?
    public let actorDisplayName: String?
    public let eventType: String              // dotted key: 'sanction.issued' etc.
    public let entityKind: String?
    public let entityId: UUID?
    public let summary: String?
    public let occurredAt: Date?

    enum CodingKeys: String, CodingKey {
        case id                 = "event_uuid"
        case groupId            = "group_id"
        case actorUserId        = "actor_user_id"
        case actorDisplayName   = "actor_display_name"
        case eventType          = "event_type"
        case entityKind         = "entity_kind"
        case entityId           = "entity_id"
        case summary
        case occurredAt         = "occurred_at"
    }

    public init(
        id: UUID,
        groupId: UUID,
        actorUserId: UUID? = nil,
        actorDisplayName: String? = nil,
        eventType: String,
        entityKind: String? = nil,
        entityId: UUID? = nil,
        summary: String? = nil,
        occurredAt: Date? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.actorUserId = actorUserId
        self.actorDisplayName = actorDisplayName
        self.eventType = eventType
        self.entityKind = entityKind
        self.entityId = entityId
        self.summary = summary
        self.occurredAt = occurredAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.actorUserId = try c.decodeIfPresent(UUID.self, forKey: .actorUserId)
        self.actorDisplayName = try c.decodeIfPresent(String.self, forKey: .actorDisplayName)
        self.eventType = try c.decode(String.self, forKey: .eventType)
        self.entityKind = try c.decodeIfPresent(String.self, forKey: .entityKind)
        self.entityId = try c.decodeIfPresent(UUID.self, forKey: .entityId)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt)
        // payload is intentionally not decoded; Foundation surface
        // renders summary + event_type only. Future slices that need
        // the payload should add it back here as `[String: JSONValue]`.
    }
}

public extension GroupEvent {
    /// Curated mapping of canonical `event_type` keys to SF Symbols.
    /// Unknown types fall back to a neutral icon — the timeline never
    /// hides events just because we didn't pick an icon yet.
    var systemImageName: String {
        switch eventType {
        case "sanction.issued":         return "exclamationmark.shield"
        case "sanction.disputed":       return "scale.3d"
        case "dispute.opened":          return "scale.3d"
        case "dispute.resolved":        return "checkmark.seal"
        case "decision_rules.set":      return "person.3.sequence"
        case "purpose.set":             return "flag"
        case "rule.created", "rule.published": return "list.bullet.rectangle"
        case "rule.archived":           return "archivebox"
        case "resource.created":        return "square.stack.3d.up"
        case "resource.archived":       return "archivebox"
        case "settlement.recorded",
             "expense.recorded",
             "obligation.created":      return "creditcard"
        case "member.invited",
             "member.joined":           return "person.crop.circle.badge.plus"
        case "member.left",
             "member.removed":          return "person.crop.circle.badge.minus"
        default:                        return "circle.fill"
        }
    }
}
