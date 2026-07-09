import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Parser de una línea → borrador de evento. Servicio on-device que convierte
/// una frase corta ("Cena viernes 8pm en casa de Pedro") en un `EventDraft`
/// vía guided generation, para pre-llenar el formulario de CreateEventView.
///
/// Mismo patrón que `EventSuggestionService` (R.6.AI.11) / R.6.AI.7, con una
/// diferencia de API: `parse(_:)` devuelve el draft directamente (`nil` si el
/// modelo no está disponible o falla) porque la vista lo aplica al form en el
/// mismo gesto — no hay estado `.loaded` que persista.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class EventDraftParserService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
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
    /// Convierte la frase del usuario en un `EventDraft` vía guided
    /// generation. Devuelve `nil` si el modelo no está disponible, el texto
    /// está vacío o el modelo falla (en ese caso `phase == .failed` con copy
    /// en español para la UI).
    public func parse(_ text: String) async -> EventDraft? {
        guard isAvailable else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        phase = .loading

        // Fecha actual como referencia para que el modelo resuelva fechas
        // absolutas ("el 12 de julio" → '2026-07-12') con el año correcto.
        // Los días relativos ('viernes', 'mañana') NO los resuelve el modelo:
        // los devuelve como hint y los convierte EventDraftDateResolver.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_MX")
        formatter.dateFormat = "EEEE d 'de' MMMM 'de' yyyy"
        let todayText = formatter.string(from: Date())

        let instructions = """
            Eres un asistente que convierte UNA frase corta describiendo un \
            evento en un EventDraft estructurado. Hoy es \(todayText).

            REGLAS PARA FECHAS — IMPORTANTE:
            - NO produces ISO 8601 para días relativos. Produces HINTS.
            - dayHint: usa 'hoy', 'mañana', 'pasado_mañana', o un día de la \
              semana en minúsculas ('viernes', 'sábado', etc.), o 'en_N_dias' \
              (ej 'en_5_dias'). SOLO si el usuario dijo una fecha exacta \
              ('el 12 de julio') devuelve 'AAAA-MM-DD' usando el año actual \
              (o el siguiente si esa fecha ya pasó este año). Vacío si no \
              menciona día.
            - timeHint: hora exacta en 24h 'HH:MM' (ej '20:00' para 8pm, \
              '14:30' para 2:30pm). Vacío si no menciona hora.
            - Si el usuario dice "el viernes" sin hora, dayHint='viernes' \
              timeHint=''.
            - Si dice "mañana a las 7pm", dayHint='mañana' timeHint='19:00'.

            REGLAS PARA TÍTULO Y UBICACIÓN:
            - title: 2-6 palabras, sin fecha, hora ni lugar. "Cena" no \
              "Cena del viernes en casa de Pedro".
            - locationText: tal como lo dijo el usuario. "casa de Pedro", \
              "restaurante Mar". Vacío si no menciona lugar o si es virtual.
            - isVirtual: true SOLO si menciona 'virtual', 'en línea', \
              'videollamada', 'Zoom', 'Meet', 'Teams' o 'FaceTime'. false en \
              cualquier otro caso.

            EJEMPLO:
            INPUT: "Cena viernes 8pm en casa de Pedro"
            OUTPUT: { title="Cena", dayHint="viernes", timeHint="20:00", \
              locationText="casa de Pedro", isVirtual=false }
            """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: trimmed,
                generating: EventDraft.self
            )
            phase = .idle
            return response.content
        } catch {
            phase = .failed(message: "No pude interpretarlo. Intenta con otras palabras o llena los campos abajo.")
            return nil
        }
    }
    #endif
}

/// Convierte los hints simbólicos de `EventDraft` a `Date` con Calendar +
/// DateComponents. Extiende `EventSuggestionDateParser` (R.6.AI.11) con
/// soporte de fechas absolutas 'AAAA-MM-DD'; delega a él los días relativos
/// ('hoy', 'mañana', lunes-domingo, 'en_N_dias'). Si nada parsea, devuelve
/// `nil` y la vista deja la fecha como estaba.
public enum EventDraftDateResolver {
    public static func resolve(dayHint rawDay: String, timeHint rawTime: String, now: Date = Date()) -> Date? {
        let dayHint = rawDay.lowercased().trimmingCharacters(in: .whitespaces)
        guard !dayHint.isEmpty else { return nil }

        // Fecha absoluta 'AAAA-MM-DD' (el modelo solo la produce cuando el
        // usuario dijo una fecha exacta).
        if let absolute = absoluteDay(from: dayHint) {
            let (hour, minute) = timeComponents(from: rawTime)
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: absolute)
        }

        // Días relativos → mismo parser que el AI Hero (R.6.AI.11).
        return EventSuggestionDateParser.parse(dateHint: dayHint, timeHint: rawTime, now: now)
    }

    /// 'AAAA-MM-DD' → medianoche de ese día en el calendario actual.
    private static func absoluteDay(from hint: String) -> Date? {
        let parts = hint.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), year >= 2000, year <= 2100,
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }

    /// 'HH:MM' 24h → (hour, minute). Default 19:00 si no hay hora (mismo
    /// default que `EventSuggestionDateParser`).
    private static func timeComponents(from rawTime: String) -> (Int, Int) {
        let parts = rawTime.trimmingCharacters(in: .whitespaces).split(separator: ":")
        if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
            return (max(0, min(23, h)), max(0, min(59, m)))
        }
        return (19, 0)
    }
}
