import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.7 — Estructura `@Generable` que el modelo llena para sugerir un
/// gasto a partir de lenguaje natural ("Cena 500 yo pagué", "Súper 250
/// dividido con Aaron y Maria, no incluye a Juan").
///
/// Doctrina founder: el modelo pre-llena el form; el usuario confirma con
/// tap. Cero RPC se dispara por el modelo. El matching de `payerName` y
/// `excludedNames` a `ContextMember.actorId` se hace en la vista.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct ExpenseSuggestion: Sendable, Equatable {
    @Guide(description: "SOLO 1-3 palabras describiendo el concepto del gasto. Ejemplos válidos: Cena, Súper, Uber, Poker, Gasolina, Renta, Boletos avión. NUNCA escribas oraciones, frases ni incluyas montos ni nombres ni preposiciones. Si el usuario dice 'cena 500' pones 'Cena'; si dice 'Moshe me debe 100 del poker' pones 'Poker'.")
    public let description: String

    @Guide(description: "Monto numérico del gasto en la moneda. Si el usuario no especifica monto, devuelve 0.")
    public let amount: Double

    @Guide(description: "Código de 3 letras de la moneda. Default MXN si el usuario no especifica.")
    public let currency: String

    @Guide(description: "Nombre EXACTO (de la lista de miembros) de quien pagó. Cadena vacía si el usuario pagó (frases tipo 'yo pagué', 'pagué', 'me debe', 'me deben').")
    public let payerName: String

    @Guide(description: "Nombres EXACTOS de los miembros que DEBEN ese gasto (participan en el split), separados por coma. Cadena vacía si todos los miembros participan por igual.")
    public let participantNames: String

    @Guide(description: "Frase corta en español explicando cómo se entendió el gasto.")
    public let rationale: String
}
#endif
