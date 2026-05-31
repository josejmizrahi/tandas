import Foundation

/// D.21B — Repository wrapping the four `list_my_inbox` / `mark_*` /
/// `my_inbox_unread_count` RPCs. iOS uses this to power the in-app
/// inbox surface that the engine writes to via `notifications_outbox`.
public struct CanonicalInboxRepository: Sendable {
    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func list(
        groupId: UUID? = nil,
        unreadOnly: Bool = false,
        limit: Int = 50
    ) async throws -> [InboxItem] {
        try await rpc.listMyInbox(
            ListMyInboxParams(groupId: groupId, unreadOnly: unreadOnly, limit: limit)
        )
    }

    public func markRead(outboxId: UUID) async throws {
        try await rpc.markInboxRead(MarkInboxReadParams(outboxId: outboxId))
    }

    @discardableResult
    public func markAllRead(groupId: UUID? = nil) async throws -> Int {
        try await rpc.markAllInboxRead(MarkAllInboxReadParams(groupId: groupId))
    }

    public func unreadCount(groupId: UUID? = nil) async throws -> Int {
        try await rpc.myInboxUnreadCount(MyInboxUnreadCountParams(groupId: groupId))
    }
}
