import Foundation

/// R.4D — notificación in-app dirigida a un actor (P1.1). Lectura PostgREST
/// directa sobre `notifications` (RLS `recipient_actor_id = current_actor_id()`);
/// mutaciones vía `mark_notification_read/archived` y
/// `mark_all_notifications_read`.
public struct RuulNotification: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let contextActorId: UUID?
    public let notificationType: String
    public let title: String
    public let body: String?
    public let targetType: String?
    public let targetId: UUID?
    /// unread → read → archived
    public let status: String
    public let createdAt: Date
    public let readAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case contextActorId = "context_actor_id"
        case notificationType = "notification_type"
        case title
        case body
        case targetType = "target_type"
        case targetId = "target_id"
        case status
        case createdAt = "created_at"
        case readAt = "read_at"
    }

    public init(
        id: UUID,
        contextActorId: UUID? = nil,
        notificationType: String,
        title: String,
        body: String? = nil,
        targetType: String? = nil,
        targetId: UUID? = nil,
        status: String = "unread",
        createdAt: Date = Date(),
        readAt: Date? = nil
    ) {
        self.id = id
        self.contextActorId = contextActorId
        self.notificationType = notificationType
        self.title = title
        self.body = body
        self.targetType = targetType
        self.targetId = targetId
        self.status = status
        self.createdAt = createdAt
        self.readAt = readAt
    }

    public var isUnread: Bool { status == "unread" }

    /// Icono por tipo (catálogo abierto — fallback genérico).
    public var symbolName: String {
        switch notificationType {
        case let t where t.hasPrefix("decision"): return "checkmark.seal"
        case let t where t.hasPrefix("rule"):     return "scroll"
        case let t where t.hasPrefix("event"):    return "calendar"
        case let t where t.hasPrefix("money"), let t where t.hasPrefix("settlement"):
            return "banknote"
        default: return "bell"
        }
    }
}
