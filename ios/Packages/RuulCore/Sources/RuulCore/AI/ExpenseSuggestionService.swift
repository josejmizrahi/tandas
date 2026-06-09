import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.7 — Servicio on-device para sugerir un gasto a partir de
/// lenguaje natural ("Cena 500 yo pagué").
///
/// Mismo patrón que `RuleSuggestionService` (R.6.AI.5 pre-aggregation):
/// pre-fetch contexto con `RuulAIContext.forExpenseSuggestion` (members
/// only — el modelo necesita los nombres para hacer match de payer y
/// excluded), inyecta como prefix compacto, modelo genera ExpenseSuggestion
/// vía guided generation. Cero tool calling.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class ExpenseSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(ExpenseSuggestion, considered: [RuulAIContext.Considered])
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
    /// Llama al modelo on-device y devuelve un `ExpenseSuggestion` vía guided
    /// generation. Si `rpc` + `contextId` están presentes, pre-aggregation
    /// con los miembros del contexto para que el modelo haga match preciso
    /// del `payerName` / `excludedNames` con miembros reales.
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
            Eres un asistente que convierte la descripción en lenguaje natural \
            de un gasto en una ExpenseSuggestion estructurada.

            Reglas estrictas:
            1. description: corta (2-6 palabras), descriptiva.
            2. amount: número exacto si lo dice el usuario; 0 si no menciona.
            3. currency: 3 letras (MXN, USD, EUR). MXN por default.
            4. payerName: nombre tal como el usuario lo dijo si menciona quien \
               pagó. Cadena vacía si dice "yo pagué" o no menciona pagador.
            5. excludedNames: nombres de miembros a excluir del split, separados \
               por coma. Cadena vacía si no hay exclusiones.
            6. Si te dan información del contexto con la lista de miembros, \
               usa los nombres EXACTOS de la lista para payerName y excludedNames.
            7. rationale: frase corta en español resumiendo cómo entendiste \
               el gasto.
            """

        do {
            let snapshot: RuulAIContext.Snapshot
            if let rpc, let contextId {
                snapshot = try await RuulAIContext.compact(
                    rpc: rpc,
                    contextId: contextId,
                    fields: RuulAIContext.forExpenseSuggestion
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
                generating: ExpenseSuggestion.self
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
