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
    @Guide(description: "Descripción corta del gasto en español, 2-6 palabras. Ejemplos: Cena, Súper, Uber al aeropuerto.")
    public let description: String

    @Guide(description: "Monto numérico del gasto en la moneda. Si el usuario no especifica monto, devuelve 0.")
    public let amount: Double

    @Guide(description: "Código de 3 letras de la moneda. Default MXN si el usuario no especifica.")
    public let currency: String

    @Guide(description: "Nombre del miembro que pagó tal y como el usuario lo dijo. Si dice 'yo pagué' o no menciona pagador, devuelve cadena vacía.")
    public let payerName: String

    @Guide(description: "Nombres de miembros a EXCLUIR del reparto, separados por coma. Cadena vacía si no se mencionan exclusiones.")
    public let excludedNames: String

    @Guide(description: "Frase corta en español explicando cómo se entendió el gasto.")
    public let rationale: String
}
#endif
