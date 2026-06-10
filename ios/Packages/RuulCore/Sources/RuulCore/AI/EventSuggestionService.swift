import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.11 — Servicio on-device para sugerir un evento desde lenguaje
/// natural. Mismo patrón pre-aggregation. Para fechas: el modelo produce
/// hints simbólicos (`dateHint`, `timeHint`), la vista los parsea con
/// `EventSuggestionDateParser` a Date concreta.
@available(iOS 26.0, *)
@MainActor
@Observable
public final class EventSuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(EventSuggestion, considered: [RuulAIContext.Considered])
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
            de un evento en una EventSuggestion estructurada.

            REGLAS PARA FECHAS — IMPORTANTE:
            - NO produces ISO 8601 ni fechas absolutas. Produces HINTS.
            - dateHint: usa 'hoy', 'mañana', 'pasado_mañana', o un día de la \
              semana en minúsculas ('viernes', 'sábado', etc.), o 'en_N_dias' \
              (ej 'en_5_dias'). Vacío si no menciona día.
            - timeHint: hora exacta en 24h 'HH:MM' (ej '20:00' para 8pm, \
              '14:30' para 2:30pm). Vacío si no menciona hora.
            - Si el usuario dice "el viernes" sin hora, dateHint='viernes' \
              timeHint=''.
            - Si dice "mañana a las 7pm", dateHint='mañana' timeHint='19:00'.

            REGLAS PARA TIPO:
            - "cena", "comida" → dinner
            - "reunión", "junta" → meeting
            - "viaje" → trip
            - "juegos", "póker", "noche de juegos" → game_night
            - "evento comunitario", "kermesse" → community_event
            - "deadline", "fecha límite", "vencimiento" → deadline
            - default → other

            REGLAS PARA TÍTULO Y UBICACIÓN:
            - title: 2-6 palabras, sin fecha. "Cena familiar" no "Cena del \
              viernes".
            - locationText: tal como lo dijo el usuario. "casa de Maria", \
              "restaurante Mar". Vacío si no menciona.

            rationale: 1 frase confirmando lo que entendiste con formato \
            "Evento X el día Z a las HH:MM en lugar".
            """

        do {
            let snapshot: RuulAIContext.Snapshot
            if let rpc, let contextId {
                snapshot = try await RuulAIContext.compact(
                    rpc: rpc,
                    contextId: contextId,
                    fields: RuulAIContext.forEventSuggestion
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
                generating: EventSuggestion.self
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

/// R.6.AI.11 — Parser para los hints simbólicos del modelo a `Date`. El
/// modelo no genera ISO 8601 (no es confiable on-device); en su lugar
/// produce strings symbólicos que esta función convierte a `Date` exacta
/// usando `Calendar.current`.
public enum EventSuggestionDateParser {
    /// Convierte `dateHint` + `timeHint` a una `Date` en el calendario actual.
    /// Si `dateHint` vacío, devuelve nil. Si `timeHint` vacío, defaultea a
    /// 19:00 (hora típica para cena/evento).
    public static func parse(dateHint rawDate: String, timeHint rawTime: String, now: Date = Date()) -> Date? {
        let dateHint = rawDate.lowercased().trimmingCharacters(in: .whitespaces)
        let timeHint = rawTime.trimmingCharacters(in: .whitespaces)
        guard !dateHint.isEmpty else { return nil }

        let calendar = Calendar.current
        let baseDay: Date?

        switch dateHint {
        case "hoy":
            baseDay = calendar.startOfDay(for: now)
        case "mañana":
            baseDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case "pasado_mañana", "pasado mañana":
            baseDay = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))
        case "lunes":     baseDay = nextWeekday(weekday: 2, from: now, calendar: calendar)
        case "martes":    baseDay = nextWeekday(weekday: 3, from: now, calendar: calendar)
        case "miércoles", "miercoles":
            baseDay = nextWeekday(weekday: 4, from: now, calendar: calendar)
        case "jueves":    baseDay = nextWeekday(weekday: 5, from: now, calendar: calendar)
        case "viernes":   baseDay = nextWeekday(weekday: 6, from: now, calendar: calendar)
        case "sábado", "sabado":
            baseDay = nextWeekday(weekday: 7, from: now, calendar: calendar)
        case "domingo":   baseDay = nextWeekday(weekday: 1, from: now, calendar: calendar)
        default:
            // "en_N_dias" pattern
            if dateHint.hasPrefix("en_") || dateHint.hasPrefix("en ") {
                let cleaned = dateHint
                    .replacingOccurrences(of: "en_", with: "")
                    .replacingOccurrences(of: "en ", with: "")
                    .replacingOccurrences(of: "_dias", with: "")
                    .replacingOccurrences(of: " dias", with: "")
                    .replacingOccurrences(of: "_días", with: "")
                    .replacingOccurrences(of: " días", with: "")
                if let n = Int(cleaned.trimmingCharacters(in: .whitespaces)) {
                    baseDay = calendar.date(byAdding: .day, value: n, to: calendar.startOfDay(for: now))
                } else {
                    baseDay = nil
                }
            } else {
                baseDay = nil
            }
        }
        guard let day = baseDay else { return nil }

        // Time parsing — HH:MM en 24h.
        let parts = timeHint.split(separator: ":")
        let hour: Int
        let minute: Int
        if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
            hour = max(0, min(23, h))
            minute = max(0, min(59, m))
        } else {
            hour = 19 // Default 7pm si no hay hora.
            minute = 0
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private static func nextWeekday(weekday target: Int, from now: Date, calendar: Calendar) -> Date {
        // Devuelve el próximo día de la semana indicado (target=1=domingo,
        // 2=lunes, ..., 7=sábado en Calendar.current). Si hoy es ese día,
        // devuelve la próxima semana.
        let today = calendar.component(.weekday, from: now)
        var delta = target - today
        if delta <= 0 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: now)) ?? now
    }
}
