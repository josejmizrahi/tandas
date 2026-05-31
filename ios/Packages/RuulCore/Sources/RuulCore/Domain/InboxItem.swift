import Foundation

/// D.21B — In-app inbox row mirroring `list_my_inbox(...)`.
/// Backed by `notifications_outbox` filtered by `recipient_user_id = auth.uid()`.
/// Each row is a delivered (or pending) notification that the engine emitted
/// for the current user. APNs push is best-effort; this surface is the
/// durable read.
public struct InboxItem: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let groupId: UUID?
    public let category: String
    public let payload: [String: RPCJSONValue]
    public let dispatchStatus: String
    public let dispatchedAt: Date?
    public let readAt: Date?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupId         = "group_id"
        case category
        case payload
        case dispatchStatus  = "dispatch_status"
        case dispatchedAt    = "dispatched_at"
        case readAt          = "read_at"
        case createdAt       = "created_at"
    }

    public init(
        id: UUID,
        groupId: UUID?,
        category: String,
        payload: [String: RPCJSONValue],
        dispatchStatus: String,
        dispatchedAt: Date?,
        readAt: Date?,
        createdAt: Date
    ) {
        self.id = id
        self.groupId = groupId
        self.category = category
        self.payload = payload
        self.dispatchStatus = dispatchStatus
        self.dispatchedAt = dispatchedAt
        self.readAt = readAt
        self.createdAt = createdAt
    }

    public var isRead: Bool { readAt != nil }
}

public extension InboxItem {
    /// Human-readable body extracted from `payload.message`. Falls back
    /// to the category key when no message is present.
    var bodyText: String {
        if case let .string(s) = payload["message"], !s.isEmpty { return s }
        return category
    }
}
