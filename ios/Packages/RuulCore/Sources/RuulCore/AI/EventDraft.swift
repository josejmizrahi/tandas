import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Parser de una línea → borrador de evento. Estructura `@Generable` que el
/// modelo llena a partir de una frase corta ("Cena viernes 8pm en casa de
/// Pedro") para pre-llenar el formulario de CreateEventView.
///
/// Mismo patrón que `EventSuggestion` (R.6.AI.11): el modelo NO produce
/// fechas absolutas confiables, así que devuelve hints simbólicos
/// (`dayHint`, `timeHint`) que iOS convierte a `Date` con
/// `EventDraftDateResolver` (Calendar + DateComponents).
///
/// Doctrina founder: el modelo pre-llena el form; el usuario confirma con
/// tap. Cero RPC se dispara por el modelo.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct EventDraft: Sendable, Equatable {
    @Guide(description: "Título corto del evento en español, 2-6 palabras. Ejemplos: 'Cena', 'Cena familiar', 'Reunión de planeación'. NO incluyas fecha, hora ni ubicación en el título. Si el usuario dice 'Cena viernes 8pm en casa de Pedro' pones 'Cena'.")
    public let title: String

    @Guide(description: "Pista del día en español. Valores aceptados: 'hoy', 'mañana', 'pasado_mañana', un día de la semana en minúsculas ('lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'), 'en_N_dias' donde N es 2-30, o una fecha absoluta 'AAAA-MM-DD' SOLO si el usuario dijo una fecha exacta (ej 'el 12 de julio' → '2026-07-12' usando el año actual dado en las instrucciones). Cadena vacía si no se mencionó día.")
    public let dayHint: String

    @Guide(description: "Hora del evento en formato 24h HH:MM (ej '20:00', '14:30'). Si el usuario dice '8pm' devuelve '20:00'; '7am' → '07:00'. Cadena vacía si no se mencionó hora.")
    public let timeHint: String

    @Guide(description: "Texto de la ubicación física tal como el usuario la dijo. Ejemplos: 'casa de Pedro', 'restaurante Mar', 'oficina'. Cadena vacía si no se mencionó ubicación o si el evento es virtual.")
    public let locationText: String

    @Guide(description: "true SOLO si el usuario indica que el evento es virtual: menciona 'virtual', 'en línea', 'videollamada', 'Zoom', 'Meet', 'Teams' o 'FaceTime'. false en cualquier otro caso.")
    public let isVirtual: Bool
}
#endif
