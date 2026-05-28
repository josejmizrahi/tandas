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

/// V2-G7 cross-primitive categories for the `GroupHistoryView` filter
/// strip. The matcher inspects `entity_kind` first (canonical, set by
/// `record_system_event`) and falls back to `event_type` dotted-prefix
/// — that way both shapes are covered without backend changes.
public enum HistoryCategory: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case money
    case decisions
    case sanctions
    case disputes
    case members
    case rules
    case culture

    public var id: String { rawValue }

    public var systemImageName: String {
        switch self {
        case .money:     return "creditcard"
        case .decisions: return "person.3.sequence"
        case .sanctions: return "exclamationmark.shield"
        case .disputes:  return "scale.3d"
        case .members:   return "person.2"
        case .rules:     return "list.bullet.rectangle"
        case .culture:   return "sparkles"
        }
    }

    public var label: LocalizedStringResource {
        switch self {
        case .money:     return L10n.History.filterMoney
        case .decisions: return L10n.History.filterDecisions
        case .sanctions: return L10n.History.filterSanctions
        case .disputes:  return L10n.History.filterDisputes
        case .members:   return L10n.History.filterMembers
        case .rules:     return L10n.History.filterRules
        case .culture:   return L10n.History.filterCulture
        }
    }

    /// Returns `true` when the event belongs to this category. Matchers
    /// are intentionally inclusive — when in doubt we surface the event
    /// rather than hide it (Foundation timeline is append-only memory).
    public func matches(_ event: GroupEvent) -> Bool {
        let type = event.eventType
        let kind = event.entityKind ?? ""

        switch self {
        case .money:
            return type.hasPrefix("expense.")
                || type.hasPrefix("settlement.")
                || type.hasPrefix("obligation.")
                || type.hasPrefix("transaction.")
                || type.hasPrefix("pool_charge.")
                || type.hasPrefix("ledger.")
                || kind == "transaction"
                || kind == "obligation"
                || kind == "money_movement"
        case .decisions:
            return type.hasPrefix("decision.")
                || type.hasPrefix("vote.")
                || type.hasPrefix("decision_rules.")
                || kind == "decision"
        case .sanctions:
            return type.hasPrefix("sanction.")
                || kind == "sanction"
        case .disputes:
            return type.hasPrefix("dispute.")
                || kind == "dispute"
        case .members:
            return type.hasPrefix("member.")
                || type.hasPrefix("invite.")
                || type.hasPrefix("role.")
                || type.hasPrefix("mandate.")
                || type.hasPrefix("contribution.")
                || type.hasPrefix("reputation.")
                || kind == "membership"
                || kind == "mandate"
                || kind == "role"
        case .rules:
            return type.hasPrefix("rule.")
                || type.hasPrefix("purpose.")
                || type.hasPrefix("boundary_policy.")
                || kind == "rule"
                || kind == "group_purpose"
                || kind == "boundary_policy"
        case .culture:
            return type.hasPrefix("cultural_norm.")
                || type.hasPrefix("ritual.")
                || kind == "cultural_norm"
                || kind == "ritual"
        }
    }
}
