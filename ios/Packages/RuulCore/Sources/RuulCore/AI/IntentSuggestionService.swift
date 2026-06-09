import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.2 — Servicio para clasificar lenguaje natural → intent en
/// `CreateIntentSheet`. Mismo patrón que `RuleSuggestionService`.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class IntentSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(IntentSuggestion)
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
            phase = .unavailable(reason: "Activa Apple Intelligence en Ajustes.")
        case .unavailable(.modelNotReady):
            phase = .unavailable(reason: "El modelo se está descargando.")
        case .unavailable:
            phase = .unavailable(reason: "Sugerencias no disponibles ahora.")
        }
        #else
        phase = .unavailable(reason: "Sugerencias no disponibles en esta versión.")
        #endif
    }

    public func reset() {
        phase = isAvailable ? .idle : phase
    }

    #if canImport(FoundationModels)
    public func suggest(prompt userPrompt: String) async {
        guard isAvailable else { return }
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        phase = .loading

        let instructions = """
            \(RuulAIContext.glossary)

            Eres un asistente que clasifica la descripción en lenguaje natural \
            del usuario al intent canónico de Ruul. Hay 7 intents:

            - event: programar una reunión, cena, evento o sesión.
            - expense: registrar un gasto o ingreso de dinero.
            - decision: abrir una propuesta para votar.
            - document: subir o adjuntar un archivo.
            - resource: registrar un activo (casa, vehículo, cuenta, equipo).
            - reservation: apartar un recurso para fechas específicas.
            - obligation: pedir una acción, aprobación o entrega a alguien \
              (incluye "deudas" personales: "le debo X a alguien").

            Si la descripción no encaja con ninguno, usa "unknown".

            Devuelve rationale corto en español (máximo 12 palabras) explicando \
            por qué elegiste ese intent.
            """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: IntentSuggestion.self
            )
            phase = .loaded(response.content)
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
    #endif
}
