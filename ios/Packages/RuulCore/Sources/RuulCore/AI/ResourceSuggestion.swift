import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.13 — Estructura `@Generable` que el modelo llena para sugerir un
/// recurso. Ej: "Casa Valle en San Miguel valor 5 millones", "Fondo común
/// del año en BBVA", "Camioneta Toyota Hilux 2022".
///
/// El modelo elige `classKey` + `subtypeKey` del taxonomy canónico de Ruul
/// (descrito en el glosario). El backend rechaza valores que no existan.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct ResourceSuggestion: Sendable, Equatable {
    @Guide(description: "Clase canónica del recurso. Valores válidos: real_estate (inmueble), vehicle (vehículo), monetary (cuenta/inversión), documents (documento), equipment (equipo), digital_assets (cripto/digital), travel (viaje), generic_other (otro).")
    public let classKey: String

    @Guide(description: "Subtype hint en minúsculas, una palabra corta. Ejemplos: 'house', 'apartment', 'land' para real_estate; 'car', 'motorcycle' para vehicle; 'bank_account', 'investment' para monetary. Si no sabes, devuelve 'generic'.")
    public let subtypeKey: String

    @Guide(description: "Nombre corto del recurso tal como lo dijo el usuario, 2-5 palabras. Ejemplos: 'Casa Valle', 'Fondo común', 'Camioneta Toyota'.")
    public let displayName: String

    @Guide(description: "Descripción adicional 1-2 oraciones si el usuario dio detalles. Cadena vacía si no.")
    public let detail: String

    @Guide(description: "Texto de ubicación si el usuario la mencionó. Ejemplos: 'San Miguel de Allende', 'BBVA cuenta corriente'. Vacío si no.")
    public let locationText: String

    @Guide(description: "Valor estimado numérico si el usuario lo mencionó (5000000, 250000, etc.). 0 si no menciona valor.")
    public let estimatedValue: Double

    @Guide(description: "Código de 3 letras de la moneda (MXN, USD, EUR). MXN por default.")
    public let currency: String

    @Guide(description: "Frase corta en español resumiendo qué entendiste.")
    public let rationale: String
}
#endif
