import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.1 — Servicio que envuelve `LanguageModelSession` para sugerir reglas
/// a partir de lenguaje natural. Verifica availability, maneja errores y
/// expone phases observables.
///
/// Pre-condiciones: iPhone con Apple Intelligence (15 Pro+/16+) con la
/// función activada en Ajustes. Si no está disponible, `phase == .unavailable`
/// y la UI debe ocultar/deshabilitar el feature graciosamente.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class RuleSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(RuleSuggestion)
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
    /// Llama al modelo on-device con instrucciones específicas y devuelve un
    /// `RuleSuggestion` estructurado vía guided generation.
    public func suggest(prompt userPrompt: String) async {
        guard isAvailable else { return }
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        phase = .loading

        let instructions = """
            Eres un asistente que convierte la descripción en lenguaje natural de \
            una regla de grupo (familia, amigos, tanda, sociedad, trust) en una \
            RuleSuggestion estructurada. Elige UNA de 5 plantillas:

            - lateFee: multa por llegar tarde a un evento.
            - sameDayCancellation: multa por cancelar la asistencia el mismo día.
            - lateReservationCancel: multa por cancelar una reservación con poco tiempo.
            - expenseAlert: alerta cuando alguien registra un gasto mayor a cierto monto.
            - textNorm: norma escrita sin multa automática.

            Reglas estrictas:
            1. Llena SÓLO los campos numéricos de la plantilla elegida; usa 0 (o cadena \
               vacía para normText) en los demás.
            2. Defaults si el usuario no especifica: thresholdMinutes=15, lateCancelHours=48, \
               expenseThreshold=5000, fineAmount=100 MXN.
            3. Título corto (máximo 8 palabras), en español, sin signos de exclamación.
            4. rationale: una frase corta en español que explique qué hace la regla y \
               cuándo aplica.
            """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: RuleSuggestion.self
            )
            phase = .loaded(response.content)
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
    #endif
}
