import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.2 — Clasificación de intent para el CreateIntentSheet.
///
/// El usuario describe en lenguaje natural lo que quiere hacer
/// ("debo 500 a Moshe", "quiero apartar la casa el viernes",
/// "votemos si vamos al concierto") y el modelo on-device clasifica
/// a una de las 7 intenciones canónicas del shell.
///
/// El backend ya tiene los flows; el modelo NO crea nada — sólo decide
/// qué form abrir. El usuario confirma con un tap.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct IntentSuggestion: Sendable, Equatable {
    @Guide(description: "Intent canónico. Valores válidos: event, expense, decision, document, resource, reservation, obligation. Si no estás seguro, devuelve unknown.")
    public let intentKey: String

    @Guide(description: "Una frase corta en español explicando por qué elegiste ese intent. Máximo 12 palabras.")
    public let rationale: String
}
#endif
