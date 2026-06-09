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
    /// R.6.AI.4 — Resumen visible de una tool call que hizo el modelo. La UI
    /// las renderiza como chips "Considerado: X" para que el founder vea qué
    /// datos del contexto miró antes de sugerir.
    public struct ToolInvocation: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let output: String

        public init(id: String, name: String, output: String) {
            self.id = id
            self.name = name
            self.output = output
        }
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(RuleSuggestion, invocations: [ToolInvocation])
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
    ///
    /// **R.6.AI.4 (2026-06-09)** — Si `rpc` + `contextId` están presentes, el
    /// modelo recibe 4 tools read-only para consultar miembros, recursos,
    /// actividad reciente y reglas existentes del contexto. Doctrina founder:
    /// los tools son SOLO lectura — el modelo no decide ni dispara escrituras.
    /// Si no se pasan, el modelo opera sin contexto (modo R.6.AI.1 original).
    public func suggest(
        prompt userPrompt: String,
        rpc: (any RuulRPCClient)? = nil,
        contextId: UUID? = nil
    ) async {
        guard isAvailable else { return }
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        phase = .loading

        let baseInstructions = """
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

        let tools: [any Tool] = {
            guard let rpc, let contextId else { return [] }
            return [
                ListContextMembersTool(rpc: rpc, contextId: contextId),
                ListContextResourcesTool(rpc: rpc, contextId: contextId),
                ListContextRecentActivityTool(rpc: rpc, contextId: contextId),
                ListContextRulesTool(rpc: rpc, contextId: contextId)
            ]
        }()

        let instructions: String
        if tools.isEmpty {
            instructions = baseInstructions
        } else {
            instructions = baseInstructions + """

                Tienes 4 tools de SOLO LECTURA para conocer el contexto antes de \
                sugerir (miembros, recursos, actividad reciente, reglas existentes). \
                Úsalos cuando ayude a personalizar la sugerencia, pero recuerda: \
                tu salida es SIEMPRE una RuleSuggestion estructurada que el usuario \
                confirma con tap. NUNCA decides por el usuario.
                """
        }

        let session = tools.isEmpty
            ? LanguageModelSession(instructions: instructions)
            : LanguageModelSession(tools: tools, instructions: instructions)
        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: RuleSuggestion.self
            )
            let invocations = Self.extractInvocations(from: session.transcript)
            phase = .loaded(response.content, invocations: invocations)
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Walk del transcript para extraer pares `(toolCall, toolOutput)` que el
    /// modelo ejecutó. Los chips de la UI consumen esto para mostrar al
    /// founder qué datos del contexto miró el modelo antes de sugerir.
    private static func extractInvocations(from transcript: Transcript) -> [ToolInvocation] {
        var outputsByCallId: [String: String] = [:]
        for entry in transcript {
            if case let .toolOutput(output) = entry {
                let text = output.segments.compactMap { segment -> String? in
                    if case let .text(textSegment) = segment {
                        return textSegment.content
                    }
                    return nil
                }.joined(separator: "\n")
                outputsByCallId[output.id] = text
            }
        }
        var result: [ToolInvocation] = []
        for entry in transcript {
            if case let .toolCalls(calls) = entry {
                for call in calls {
                    let output = outputsByCallId[call.id] ?? ""
                    result.append(ToolInvocation(id: call.id, name: call.toolName, output: output))
                }
            }
        }
        return result
    }
    #endif
}
