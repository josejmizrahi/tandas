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
            \(RuulAIContext.glossary)

            Eres un asistente que convierte la descripción en lenguaje natural \
            de un gasto compartido en una ExpenseSuggestion estructurada.

            MODELO DE DATOS (memorízalo):
            - payerName: nombre del miembro que PUSO el dinero. Cadena vacía = \
              el usuario actual (yo).
            - participantNames: lista de nombres separados por coma de quienes \
              DEBEN ese dinero (los deudores). Cadena vacía = TODOS los miembros \
              participan en el split.

            REGLA CRÍTICA — semántica del español:
            La frase "X me debe Y" significa literalmente "X owes me Y". El que \
            pagó / puso el dinero es el USUARIO ACTUAL (yo). El deudor es X. NO \
            es lo mismo que "X pagó". Aquí X es el que tiene que devolverme \
            dinero a mí.

            Ejemplo trabajado paso a paso:

            INPUT: "Moshe me debe 100 pesos del poker"
            RAZONAMIENTO:
              1. "Moshe me debe" = "Moshe owes me" → Moshe es el DEUDOR, no el pagador.
              2. Si Moshe debe, alguien le prestó. Ese alguien es el usuario (yo).
              3. → payerName = "" (yo puse el dinero).
              4. → participantNames = "Moshe" (solo Moshe debe).
              5. → amount = 100.
              6. → description = "Poker".
              7. → rationale = "Yo pagué. Moshe debe 100 del poker."
            OUTPUT correcto:
              { description="Poker", amount=100, currency="MXN", \
                payerName="", participantNames="Moshe", \
                rationale="Yo pagué. Moshe debe." }

            MÁS PATRONES (sigue UNO EXACTO):

            • "X me debe Y" → payerName="", participantNames="X", amount=Y.
            • "Le debo X a Y" → payerName="Y", participantNames="", amount=X.
            • "Cena Y dividida entre todos" / "Pagué Y entre todos" → \
              payerName="", participantNames="", amount=Y.
            • "X pagó Y para Z" / "X pagó Y, le toca a Z" → payerName="X", \
              participantNames="Z", amount=Y.
            • "Pagué X yo, dividir con A y B" → payerName="", \
              participantNames="A, B", amount=X.

            REGLAS ADICIONALES:
            - description: SOLO 1-3 palabras del CONCEPTO (Cena, Poker, Súper).
            - amount: número exacto del usuario; 0 si no menciona.
            - currency: 3 letras (MXN, USD, EUR). MXN default.
            - Si te dan lista de miembros, usa nombres EXACTOS de la lista para \
              payerName y participantNames. No inventes.
            - rationale: 1 frase, formato "X pagó. Y debe(n)." (e.g., \
              "Yo pagué. Moshe debe.").

            VALIDACIÓN ANTES DE RESPONDER:
            Re-lee tu output. Si el usuario dijo "X me debe", el rationale debe \
            empezar con "Yo pagué.". Si dice "le debo a X", debe empezar con \
            "X pagó.". Si no concuerda, corrige antes de entregar.
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
