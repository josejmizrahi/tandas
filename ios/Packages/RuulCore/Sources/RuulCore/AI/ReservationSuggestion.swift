import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.12 — Estructura `@Generable` que el modelo llena para sugerir una
/// reservación. Ej: "Este sábado a las 6pm", "Del viernes al domingo",
/// "Para Maria el lunes a las 10am hasta las 5pm".
///
/// Mismo patrón de fechas que `EventSuggestion`: el modelo produce hints
/// simbólicos, `EventSuggestionDateParser` los convierte a Date.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct ReservationSuggestion: Sendable, Equatable {
    @Guide(description: "Pista del día de inicio en español. Valores: 'hoy', 'mañana', 'pasado_mañana', día de la semana en minúsculas, o 'en_N_dias'. Cadena vacía si no se mencionó.")
    public let startDateHint: String

    @Guide(description: "Hora de inicio en 24h 'HH:MM'. Vacío si no se mencionó.")
    public let startTimeHint: String

    @Guide(description: "Pista del día de fin. Mismos valores que startDateHint. Si el usuario dijo solo un día, repítelo aquí. Si no se mencionó duración, déjalo vacío y el iOS asume el mismo día.")
    public let endDateHint: String

    @Guide(description: "Hora de fin en 24h 'HH:MM'. Si no se mencionó, déjalo vacío.")
    public let endTimeHint: String

    @Guide(description: "Nombre EXACTO del miembro para quien se reserva, si el usuario menciona 'para X'. Cadena vacía si la reserva es para uno mismo.")
    public let reservedForName: String

    @Guide(description: "Frase corta en español resumiendo qué entendiste con formato 'Reserva el día Z a las HH:MM hasta el día W a las HH:MM'.")
    public let rationale: String
}
#endif
