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

            Modelo de datos:
            - payerName = quién PUSO el dinero (cadena vacía = el usuario actual).
            - participantNames = quiénes DEBEN ese gasto / participan en el split \
              (cadena vacía = TODOS los miembros del contexto).

            Patrones canónicos (sigue uno EXACTO, no inventes):

            1. "X me debe Y" / "X me debe Y pesos":
               → payerName="" (yo puse el dinero), participantNames="X" (solo X debe), amount=Y.

            2. "Le debo X a Y" / "Le debo X pesos a Y":
               → payerName="Y" (Y puso el dinero), participantNames="" (yo soy el único \
                 que debe — el campo vacío significa default, pero aquí el split \
                 es solo conmigo; déjalo vacío y el wizard lo resuelve), amount=X.

            3. "Cena 500 dividida entre todos" / "Pagué 500 entre todos":
               → payerName="" (yo pagué), participantNames="" (todos), amount=500.

            4. "X pagó Y para Z" / "X pagó Y, le toca a Z":
               → payerName="X", participantNames="Z" (solo Z debe), amount=Y.

            5. "Pagué X yo, dividir con A y B":
               → payerName="" (yo), participantNames="A, B" (solo A y B deben), amount=X.

            Reglas adicionales:
            - description: corta (2-6 palabras), descriptiva del gasto.
            - amount: número exacto si lo dice el usuario; 0 si no menciona.
            - currency: 3 letras (MXN, USD, EUR). MXN por default.
            - Si te dan lista de miembros del contexto, usa nombres EXACTOS de la lista \
              para payerName y participantNames. No inventes nombres.
            - rationale: frase corta en español resumiendo qué entendiste, en formato \
              "X pagó. Y debe(n)." (e.g., "Yo pagué. Moshe debe.")
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
