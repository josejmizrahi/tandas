import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.3 — Resumen libre del feed de actividad. A diferencia de
/// `RuleSuggestionService` / `IntentSuggestionService` que usan guided
/// generation (Generable), este servicio devuelve texto libre porque el
/// resultado es una frase narrativa, no datos estructurados.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class ActivitySummaryService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case loaded(String)
        case unavailable(reason: String)
        case failed(message: String)
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
            phase = .unavailable(reason: "Resumen no disponible ahora.")
        }
        #else
        phase = .unavailable(reason: "Resumen no disponible en esta versión.")
        #endif
    }

    public func reset() {
        phase = isAvailable ? .idle : phase
    }

    #if canImport(FoundationModels)
    /// El caller pasa un input ya pre-agregado (counts por kind + highlights).
    /// El modelo lo convierte en una frase narrativa en español.
    public func summarize(input: String) async {
        guard isAvailable else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        phase = .loading

        let instructions = """
            \(RuulAIContext.glossary)

            Eres un asistente que resume la actividad reciente del usuario en \
            Ruul (un app de contextos compartidos: familias, grupos, sociedades).

            Recibes un resumen estructurado con counts por tipo y highlights. \
            Convierte eso en 1-2 oraciones naturales en español, tono neutro \
            y conciso. Máximo 40 palabras. No uses listas ni viñetas — sólo \
            prosa fluida. No saludes. No prometas nada — solo describe.

            Ejemplo de salida: "Esta semana registraste 3 gastos en Cena Semanal \
            y aprobaste una decisión sobre las próximas vacaciones."
            """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: trimmed)
            phase = .loaded(response.content)
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
    #endif
}
