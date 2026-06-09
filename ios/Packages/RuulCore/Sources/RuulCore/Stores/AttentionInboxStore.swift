import Foundation

/// F.NAV.0 — Store long-lived del `attention_inbox()`. Long-lived porque el
/// Home consulta atención cross-context al arrancar y tras refresh. Cada
/// item viene canónico del backend; iOS no infiere reasons.
@MainActor
@Observable
public final class AttentionInboxStore {
    public private(set) var items: [AttentionItem] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public func load() async {
        if items.isEmpty { phase = .loading }
        do {
            items = try await rpc.attentionInbox()
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// R.5Z.fix.CC.2.3 — descarta un attention item (status='dismissed' en
    /// backend). Optimistic UI: remueve el item local primero, refresca
    /// después. Si el RPC falla, recarga para resincronizar.
    public func dismiss(itemId: UUID) async {
        items.removeAll { $0.subjectId == itemId }
        do {
            try await rpc.dismissAttentionItem(itemId: itemId)
        } catch {
            // Resincroniza si falló (ya logueó el error via runner si el
            // caller lo wrapeó; AttentionInboxStore no tiene runner).
            await load()
        }
    }

    public func reset() {
        items = []
        phase = .idle
    }
}
