import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.11 — Estructura `@Generable` que el modelo llena para sugerir un
/// evento. Ej: "Cena el viernes 8pm en casa de Maria", "Reunión el lunes
/// próximo a las 10am", "Noche de juegos el sábado".
///
/// Para fechas: el modelo NO intenta producir ISO 8601 directo (no es
/// confiable). En su lugar produce strings simbólicos (`dateHint`,
/// `timeHint`) que el iOS parsea con date components + Calendar.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct EventSuggestion: Sendable, Equatable {
    @Guide(description: "Título corto del evento en español, 2-6 palabras. Ejemplos: 'Cena familiar', 'Reunión de planeación', 'Noche de juegos'. NO incluyas la fecha en el título.")
    public let title: String

    @Guide(description: "Tipo canónico del evento. Valores: dinner (cena), meeting (reunión), trip (viaje), game_night (noche de juegos), community_event (evento comunitario), deadline (fecha límite), other (otro).")
    public let eventTypeKey: String

    @Guide(description: "Pista del día relativa en español. Valores aceptados: 'hoy', 'mañana', 'pasado_mañana', o un día de la semana en minúsculas ('lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'), o 'en_N_dias' donde N es 2-30. Cadena vacía si no se mencionó día.")
    public let dateHint: String

    @Guide(description: "Hora del evento en formato 24h HH:MM (ej '20:00', '14:30'). Si el usuario dice '8pm' devuelve '20:00'; '7am' → '07:00'. Cadena vacía si no se mencionó hora.")
    public let timeHint: String

    @Guide(description: "Texto de la ubicación tal como el usuario la dijo. Ejemplos: 'casa de Maria', 'restaurante Mar', 'oficina'. Cadena vacía si no se mencionó ubicación.")
    public let locationText: String

    @Guide(description: "Frase corta en español resumiendo qué entendiste, en formato 'Evento X el día Z a las HH:MM en lugar'. Ejemplo: 'Cena el viernes a las 20:00 en casa de Maria'.")
    public let rationale: String
}
#endif
