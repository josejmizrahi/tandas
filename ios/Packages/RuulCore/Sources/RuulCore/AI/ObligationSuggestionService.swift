import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.10 — Servicio on-device para sugerir un compromiso de acción.
/// Mismo patrón pre-aggregation que los demás (R.6.AI.5).
@available(iOS 26.0, *)
@MainActor
@Observable
public final class ObligationSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(ObligationSuggestion, considered: [RuulAIContext.Considered])
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
            \(RuulAIContext.glossary)

            Eres un asistente que convierte la descripción en lenguaje natural \
            de un compromiso/tarea en una ObligationSuggestion estructurada.

            REGLAS:
            1. debtorName: nombre EXACTO de la lista de miembros del deudor. \
               Si el usuario dice "yo me comprometo" o "me toca", cadena vacía.
            2. title: imperativo corto (3-8 palabras). Ej: "Entregar reporte", \
               "Aprobar gasto del palco", "Llevar el postre".
            3. detail: oración adicional con contexto. Vacío si el título basta.
            4. kindKey: UNO de action/approval/delivery/attendance/document/\
               reservation/custom según el verbo. Ejemplos:
               - "entregar", "llevar" → delivery
               - "aprobar", "validar" → approval
               - "asistir", "venir" → attendance
               - "firmar", "subir documento" → document
               - "reservar" → reservation
               - default → action
            5. hasDueDate: true si menciona fecha (mañana, viernes, en 3 días, \
               el 15, etc.); false si no.
            6. rationale: 1 frase resumiendo lo que entendiste.

            Usa nombres EXACTOS de los miembros listados. No inventes.
            """

        do {
            let snapshot: RuulAIContext.Snapshot
            if let rpc, let contextId {
                snapshot = try await RuulAIContext.compact(
                    rpc: rpc,
                    contextId: contextId,
                    fields: RuulAIContext.forObligationSuggestion
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
                generating: ObligationSuggestion.self
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
