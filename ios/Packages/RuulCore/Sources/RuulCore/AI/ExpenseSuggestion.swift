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

    @Guide(description: "Nombre EXACTO del miembro que PUSO el dinero. Cadena vacía cuando el usuario actual (yo) puso el dinero. CRÍTICO: 'X me debe Y' significa que X DEBE; el que pagó es YO. En ese caso pon cadena vacía aquí (no X). Solo pon un nombre si el usuario dijo explícitamente que esa persona pagó.")
    public let payerName: String

    @Guide(description: "Nombres EXACTOS de los miembros DEUDORES (los que deben ese dinero), separados por coma. Cadena vacía cuando TODOS los miembros participan por igual. CRÍTICO: 'X me debe Y' → pon SOLO 'X' acá (solo X debe). 'Le debo a Y' → cadena vacía (yo soy el único deudor).")
    public let participantNames: String

    @Guide(description: "Frase corta en español explicando cómo se entendió el gasto.")
    public let rationale: String
}
#endif
