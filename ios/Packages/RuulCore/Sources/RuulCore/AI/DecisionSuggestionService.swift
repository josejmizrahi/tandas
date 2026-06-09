import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.8 — Servicio on-device para sugerir una decisión desde lenguaje
/// natural. Mismo patrón pre-aggregation que los demás (R.6.AI.5).
@available(iOS 26.0, *)
@MainActor
@Observable
public final class DecisionSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(DecisionSuggestion, considered: [RuulAIContext.Considered])
        #endif
    }

    public private(set) var phase: Phase = .idle

    #if canImport(FoundationModels)
    private let model = SystemLanguageModel.default
    #endif

    public init() {
        refreshAvailability()
    }

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = model.availability { return true }
        return false
        #else
        return false
        #endif
    }

    public func refreshAvailability() {
        #if canImport(FoundationModels)
        switch model.availability {
        case .available:
            if case .unavailable = phase { phase = .idle }
        case .unavailable(.deviceNotEligible):
            phase = .unavailable(reason: "Este dispositivo no soporta Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            phase = .unavailable(reason: "Activa Apple Intelligence en Ajustes para usar sugerencias.")
        case .unavailable(.modelNotReady):
            phase = .unavailable(reason: "El modelo se está descargando. Intenta de nuevo en unos minutos.")
        case .unavailable:
            phase = .unavailable(reason: "Las sugerencias no están disponibles ahora.")
        }
        #else
        phase = .unavailable(reason: "Las sugerencias no están disponibles en esta versión.")
        #endif
    }

    public func reset() {
        phase = isAvailable ? .idle : phase
    }

    #if canImport(FoundationModels)
    public func suggest(
        prompt userPrompt: String,
        rpc: (any RuulRPCClient)? = nil,
        contextId: UUID? = nil
    ) async {
        guard isAvailable else { return }
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        phase = .loading

        let instructions = """
            Eres un asistente que convierte una propuesta en lenguaje natural en \
            una DecisionSuggestion estructurada para votar en un grupo \
            (familia, amigos, sociedad).

            REGLAS:
            1. title: formato pregunta o acción corta (4-10 palabras). Ejemplos:
               - "¿Compramos el coche nuevo?"
               - "Cambiar la cena al sábado"
               - "Aprobar el gasto del palco"
            2. detail: una frase adicional con contexto si el usuario dio detalles.
               Cadena vacía si el título ya es suficiente.
            3. decisionKind: elige UNO de:
               - "simple_majority" (default): mayoría simple basta.
               - "unanimous": cuando dice "todos tienen que aprobar".
               - "two_thirds": cuando dice "dos tercios" o "mayoría calificada".
            4. rationale: 1 frase corta en español que confirme cómo entendiste.

            Si te dan lista de miembros del contexto, NO inventes nombres en el
            título — la votación incluye a todos los miembros automáticamente.
            """

        do {
            let snapshot: RuulAIContext.Snapshot
            if let rpc, let contextId {
                snapshot = try await RuulAIContext.compact(
                    rpc: rpc,
                    contextId: contextId,
                    fields: RuulAIContext.forDecisionSuggestion
                )
            } else {
                snapshot = RuulAIContext.Snapshot(prefix: "", considered: [])
            }

            let promptBody = snapshot.prefix.isEmpty
                ? userPrompt
                : "\(snapshot.prefix)\n\nPetición del usuario: \(userPrompt)"

            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: promptBody,
                generating: DecisionSuggestion.self
            )
            phase = .loaded(response.content, considered: snapshot.considered)
        } catch {
            let raw = (error as NSError)
            let typeName = String(describing: type(of: error))
            phase = .failed(message: "\(typeName): \(raw.localizedDescription)")
        }
    }
    #endif
}
