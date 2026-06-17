import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// D.CATALOG.B — Servicio on-device para sugerir `documentType` + `title`
/// al subir un documento. Usa filename + descripción opcional del user como
/// prompt. NO analiza el contenido del archivo (FoundationModels actual no
/// expone visión multimodal); cuando esté disponible se extiende.
///
/// Pre-aggregation pattern (R.6.AI.5): si se pasa `recommendedTypes` del
/// resource_subtype destino, se inyectan como hint en el prompt para que
/// el modelo priorice esos values.
///
/// Pre-condiciones: iPhone con Apple Intelligence activado. Si no está
/// disponible, `phase == .unavailable` y la UI esconde el hero.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class DocumentSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(DocumentSuggestion)
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
    /// Pide al modelo on-device una sugerencia. `userPrompt` es la
    /// descripción libre del user (filename + nota). `recommendedTypes`
    /// es la lista priorizada del resource_subtype (D.CATALOG.A) si el
    /// documento va a un resource específico.
    public func suggest(
        prompt userPrompt: String,
        fileName: String? = nil,
        recommendedTypes: [String] = []
    ) async {
        guard isAvailable else { return }
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || fileName != nil else { return }

        phase = .loading

        let recommendedHint = recommendedTypes.isEmpty
            ? ""
            : "\n\nValores recomendados para este recurso (priorízalos si encajan): \(recommendedTypes.joined(separator: ", ")).\n"

        let instructions = """
            Eres un asistente que clasifica documentos legales y administrativos. \
            El usuario está adjuntando un documento a su espacio en Ruul (familia, \
            grupo, sociedad, trust). Analiza el nombre del archivo y la descripción \
            que dé el usuario, y elige UNO de los 8 tipos canónicos:

            - contract: contrato escrito (compraventa, servicios, arrendamiento, partnership).
            - receipt: comprobante de pago, factura simple, ticket.
            - id: identificación oficial (INE, pasaporte, licencia).
            - statement: estado de cuenta bancario, reporte financiero, mantenimiento.
            - photo: fotografía o imagen sin texto formal.
            - other: cualquier documento que no encaje en los demás.
            - policy: póliza de seguro o documento de policy formal.
            - certificate: escritura, certificado, título de propiedad, garantía.\(recommendedHint)

            Reglas estrictas:
            1. documentType debe ser EXACTAMENTE uno de esos 8 strings (lowercase).
            2. title: máximo 8 palabras en español, capitalizado normalmente.
            3. rationale: una frase corta en español explicando la elección.
            4. Si el prompt es ambiguo, elige 'other' antes de inventar contexto.
            """

        let promptBody: String
        if let fileName, !fileName.isEmpty {
            promptBody = "Archivo: \(fileName)\nDescripción del usuario: \(trimmed)"
        } else {
            promptBody = trimmed
        }

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: promptBody,
                generating: DocumentSuggestion.self
            )
            phase = .loaded(response.content)
        } catch {
            let raw = (error as NSError)
            let typeName = String(describing: type(of: error))
            let detail = "\(typeName): \(raw.localizedDescription)"
            phase = .failed(message: detail)
        }
    }
    #endif
}
