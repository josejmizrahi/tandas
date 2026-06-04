import Foundation
import Observation

/// R.2V.4 — store de similitudes/sugerencias por contexto. Carga
/// `context_similarity` + `relationship_suggestions` al abrir el home y mantiene
/// el set de dismissals locales (sobrevive sólo a la sesión; el backend emite
/// `suggestion.dismissed` para auditoría).
@MainActor
@Observable
public final class SimilarityStore {
    public private(set) var similar: [ContextSimilarityCandidate] = []
    public private(set) var suggestions: [RelationshipSuggestion] = []
    public private(set) var phase: StorePhase = .idle

    /// Dismissals locales — la UI filtra al renderizar. Identificamos por par
    /// `(min(a,b), max(a,b))` para que orden no importe.
    public private(set) var dismissed: Set<DismissKey> = []

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(
        rpc: any RuulRPCClient,
        previewSimilar: [ContextSimilarityCandidate],
        previewSuggestions: [RelationshipSuggestion] = []
    ) {
        self.rpc = rpc
        self.similar = previewSimilar
        self.suggestions = previewSuggestions
        self.phase = .loaded
    }

    /// Hidrata `similar` y `suggestions` para el contexto dado. Cualquier error
    /// pone phase=failed pero los arrays quedan en su estado previo.
    public func load(contextId: UUID, myActorId: UUID?) async {
        phase = .loading
        do {
            async let similarT = rpc.contextSimilarity(contextId: contextId)
            async let suggestionsT = rpc.relationshipSuggestions(actorId: myActorId)
            let (s, sg) = try await (similarT, suggestionsT)
            // Filtrar localmente las dismissed para evitar re-mostrar.
            similar = s.filter { c in
                !dismissed.contains(DismissKey(
                    a: min(contextId, c.contextId),
                    b: max(contextId, c.contextId),
                    type: .contextDuplicate
                ))
            }
            suggestions = sg.filter { s in
                !dismissed.contains(DismissKey(
                    a: s.aContextId, b: s.bContextId,
                    type: .relationshipContains
                ))
            }
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Descarta una sugerencia (local + backend). El backend emite
    /// `suggestion.dismissed` para auditoría; localmente la quitamos del array.
    public func dismiss(
        subjectA: UUID,
        subjectB: UUID,
        type: SuggestionType
    ) async {
        let key = DismissKey(
            a: min(subjectA, subjectB),
            b: max(subjectA, subjectB),
            type: type
        )
        dismissed.insert(key)
        // Optimistic: remove de la UI inmediato
        if type == .contextDuplicate {
            similar.removeAll { c in
                let k = DismissKey(
                    a: min(c.contextId, subjectA == c.contextId ? subjectB : subjectA),
                    b: max(c.contextId, subjectA == c.contextId ? subjectB : subjectA),
                    type: .contextDuplicate
                )
                return k == key
            }
        }
        if type == .relationshipContains {
            suggestions.removeAll { s in
                let k = DismissKey(
                    a: min(s.aContextId, s.bContextId),
                    b: max(s.aContextId, s.bContextId),
                    type: .relationshipContains
                )
                return k == key
            }
        }
        // Backend (best-effort; si falla quedó en local set sólo)
        _ = try? await rpc.dismissSuggestion(
            subjectA: subjectA, subjectB: subjectB, suggestionType: type
        )
    }

    public func reset() {
        similar = []
        suggestions = []
        dismissed = []
        phase = .idle
    }

    public struct DismissKey: Hashable, Sendable {
        public let a: UUID
        public let b: UUID
        public let type: SuggestionType
    }
}
