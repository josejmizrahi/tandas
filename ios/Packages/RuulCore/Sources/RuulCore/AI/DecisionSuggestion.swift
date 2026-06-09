import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.8 — Estructura `@Generable` que el modelo llena para sugerir una
/// decisión a partir de lenguaje natural ("¿Compramos el coche nuevo?",
/// "Cambiamos la cena al sábado", "Aprobamos el gasto del palco").
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct DecisionSuggestion: Sendable, Equatable {
    @Guide(description: "Pregunta o título corto de la decisión en español, 4-10 palabras. Comienza idealmente con un verbo o pregunta. Ejemplos: '¿Compramos el coche nuevo?', 'Cambiar la cena al sábado'.")
    public let title: String

    @Guide(description: "Descripción breve adicional con contexto en español, máximo 1-2 oraciones. Cadena vacía si el título ya basta.")
    public let detail: String

    @Guide(description: "Tipo canónico de decisión. Valores válidos: 'simple_majority' (mayoría simple, default), 'unanimous' (todos deben aprobar), 'two_thirds' (2/3 de los miembros).")
    public let decisionKind: String

    @Guide(description: "Frase corta en español resumiendo qué entendiste de la propuesta.")
    public let rationale: String
}
#endif
