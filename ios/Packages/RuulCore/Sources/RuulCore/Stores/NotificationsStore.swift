import Foundation
import Observation

/// R.4D (P1.1) — centro de notificaciones. Long-lived en el
/// `DependencyContainer` para que el badge de no-leídas sea transversal.
/// Lectura PostgREST (RLS recipient-only); mutaciones vía los RPCs de marcado.
@MainActor
@Observable
public final class NotificationsStore {
    public private(set) var notifications: [RuulNotification] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient
    private let pageSize = 50

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public var unreadCount: Int { notifications.filter(\.isUnread).count }

    public func load() async {
        if notifications.isEmpty { phase = .loading }
        do {
            notifications = try await rpc.listMyNotifications(limit: pageSize)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Marca una como leída (optimista; resync en error).
    public func markRead(_ notification: RuulNotification) async {
        guard notification.isUnread else { return }
        do {
            try await rpc.markNotificationRead(notificationId: notification.id)
            await load()
        } catch {
            await load()
        }
    }

    /// Archiva (desaparece de la lista) — optimista; resync en error.
    public func archive(_ notification: RuulNotification) async throws {
        notifications.removeAll { $0.id == notification.id }
        do {
            try await rpc.markNotificationArchived(notificationId: notification.id)
        } catch {
            await load()
            throw error
        }
    }

    public func markAllRead() async throws {
        try await rpc.markAllNotificationsRead(contextId: nil)
        await load()
    }

    public func reset() {
        notifications = []
        phase = .idle
    }
}
