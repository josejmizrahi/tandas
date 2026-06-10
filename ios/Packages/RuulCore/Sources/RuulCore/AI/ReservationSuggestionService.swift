import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.12 — Servicio on-device para sugerir una reservación desde
/// lenguaje natural. Misma estrategia de fechas que EventSuggestion:
/// el modelo produce hints simbólicos parseados por
/// `EventSuggestionDateParser`.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class ReservationSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(ReservationSuggestion, considered: [RuulAIContext.Considered])
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
            de una reservación de un recurso en una ReservationSuggestion \
            estructurada.

            El usuario YA eligió el recurso (casa, palco, vehículo, etc.). \
            Tu tarea es entender SOLO las fechas y opcionalmente para quién \
            es la reserva.

            REGLAS DE FECHAS:
            - Producir hints simbólicos, NO ISO 8601.
            - startDateHint y endDateHint: 'hoy', 'mañana', día de la semana \
              ('viernes'), o 'en_N_dias'.
            - startTimeHint y endTimeHint: 'HH:MM' en 24h.
            - Si el usuario dice "el sábado a las 6pm", startDateHint='sábado' \
              startTimeHint='18:00', endDateHint='sábado' endTimeHint='' \
              (iOS asume mismo día por unas horas).
            - Si dice "del viernes al domingo", startDateHint='viernes' \
              endDateHint='domingo'.
            - Si dice "este lunes de 10am a 5pm", startDateHint='lunes' \
              startTimeHint='10:00' endDateHint='lunes' endTimeHint='17:00'.

            reservedForName: nombre EXACTO de miembro si dice "para X", vacío \
            si la reserva es para uno mismo.

            rationale: 1 frase resumen.
            """

        do {
            let snapshot: RuulAIContext.Snapshot
            if let rpc, let contextId {
                snapshot = try await RuulAIContext.compact(
                    rpc: rpc,
                    contextId: contextId,
                    fields: RuulAIContext.forReservationSuggestion
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
                generating: ReservationSuggestion.self
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
