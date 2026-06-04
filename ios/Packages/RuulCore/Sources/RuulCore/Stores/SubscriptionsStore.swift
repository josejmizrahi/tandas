import Foundation
import Observation

/// R.3A — Suscripciones activas del actor actual. Long-lived: el surface
/// es transversal (botón "Vigilar" en ResourceDetail, DecisionDetail,
/// ObligationDetail, etc.) y queremos saber el estado actual sin pegar al
/// backend en cada detalle.
@MainActor
@Observable
public final class SubscriptionsStore {
    public private(set) var subscriptions: [Subscription] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview init.
    public init(rpc: any RuulRPCClient, previewSubscriptions: [Subscription]) {
        self.rpc = rpc
        self.subscriptions = previewSubscriptions
        self.phase = .loaded
    }

    /// Carga `list_my_subscriptions()`.
    public func load() async {
        if subscriptions.isEmpty { phase = .loading }
        do {
            let list = try await rpc.listMySubscriptions()
            subscriptions = list.subscriptions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func reset() {
        subscriptions = []
        phase = .idle
    }

    /// Sub activa del caller para `(targetType, targetId)`, o nil.
    public func current(targetType: SubscriptionTargetType, targetId: UUID) -> Subscription? {
        subscriptions.first { $0.targetType == targetType && $0.targetId == targetId }
    }

    /// Suscribe (o re-clasifica) — el backend es idempotente y reactiva si era
    /// soft-removed. Local: reemplaza la fila o la inserta.
    @discardableResult
    public func subscribe(
        targetType: SubscriptionTargetType,
        targetId: UUID,
        subscriptionType: SubscriptionType,
        notes: String? = nil
    ) async throws -> UUID {
        let id = try await rpc.subscribe(
            targetType: targetType,
            targetId: targetId,
            subscriptionType: subscriptionType,
            notes: notes
        )
        await load()
        return id
    }

    /// Cancela la sub indicada. Idempotente.
    public func unsubscribe(subscriptionId: UUID) async throws {
        _ = try await rpc.unsubscribe(subscriptionId: subscriptionId)
        subscriptions.removeAll { $0.id == subscriptionId }
    }
}
