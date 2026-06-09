import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.1 + R.6.AI.5 — Servicio on-device para sugerir reglas a partir de
/// lenguaje natural. Verifica availability, maneja errores y expone phases
/// observables.
///
/// **R.6.AI.5 (2026-06-09)** — Migrado a patrón pre-aggregation. En vez de
/// dar tools al modelo (que consumían ~1200 tokens en definitions y volaban
/// el context window de 4096 al primer roundtrip), pre-fetch el slice del
/// contexto vía `RuulAIContext.compact` y lo inyectamos como prefix del
/// prompt. Una sola llamada a `context_summary`, prefix compacto (~200 tokens),
/// budget protegido. Ver `RuulAIContext.swift` para la doctrina.
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
        case loaded(RuleSuggestion, considered: [RuulAIContext.Considered])
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
    /// Llama al modelo on-device y devuelve un `RuleSuggestion` estructurado
    /// vía guided generation. Si `rpc` + `contextId` están presentes, hace
    /// pre-aggregation del contexto antes de prompt (recommended). Si no, el
    /// modelo opera sin contexto (fallback).
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
            5. Si te dan información del contexto (miembros, recursos, reglas existentes), \
               úsala para personalizar título y rationale, pero NO dupliques una regla \
               que ya exista.
            """

        do {
            let snapshot: RuulAIContext.Snapshot
            if let rpc, let contextId {
                snapshot = try await RuulAIContext.compact(
                    rpc: rpc,
                    contextId: contextId,
                    fields: RuulAIContext.forRuleSuggestion
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
                generating: RuleSuggestion.self
            )
            phase = .loaded(response.content, considered: snapshot.considered)
        } catch {
            // Surfaceo descripción + tipo real del error para diagnosticar
            // en device. Reemplaza el genérico "Algo salió mal" sin pista.
            let raw = (error as NSError)
            let typeName = String(describing: type(of: error))
            let detail = "\(typeName): \(raw.localizedDescription)"
            phase = .failed(message: detail)
        }
    }
    #endif
}
