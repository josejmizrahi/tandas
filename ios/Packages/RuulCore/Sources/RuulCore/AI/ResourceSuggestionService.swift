import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.13 — Servicio on-device para sugerir un recurso desde lenguaje
/// natural. Mismo patrón pre-aggregation. El subtype hint que da el modelo
/// se resuelve contra la taxonomy real vía RPC `listResourceSubtypes`.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class ResourceSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(ResourceSuggestion, considered: [RuulAIContext.Considered])
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
            de un recurso (casa, vehículo, cuenta, etc.) en una \
            ResourceSuggestion estructurada para registrar en Ruul.

            REGLAS DE CLASE (classKey — elige UNA exacta del glosario):
            - casa, departamento, terreno, oficina, local → real_estate
            - carro, camioneta, moto, bicicleta, lancha → vehicle
            - cuenta bancaria, inversión, fondo, acciones → monetary
            - contrato, papel, documento, identificación → documents
            - herramienta, electrodoméstico, equipo → equipment
            - cripto, NFT, dominio web, app → digital_assets
            - vuelo, hotel, paquete, reservación → travel
            - cualquier otra cosa → generic_other

            REGLAS DE SUBTYPE (subtypeKey — hint en minúsculas):
            - real_estate: house, apartment, land, office, retail
            - vehicle: car, motorcycle, bicycle, boat
            - monetary: bank_account, investment, savings
            - default cuando no estás seguro: 'generic'

            REGLAS DE NOMBRE:
            - displayName: 2-5 palabras tal como lo dijo el user. \
              "Casa Valle" no "La casa que tenemos en Valle".
            - detail: oración con contexto si el usuario dio detalles.

            VALOR:
            - estimatedValue: número exacto si lo dice, 0 si no.
            - currency: MXN default.

            rationale: 1 frase resumiendo lo que entendiste.
            """

        do {
            let snapshot: RuulAIContext.Snapshot
            if let rpc, let contextId {
                snapshot = try await RuulAIContext.compact(
                    rpc: rpc,
                    contextId: contextId,
                    fields: RuulAIContext.forResourceSuggestion
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
                generating: ResourceSuggestion.self
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
