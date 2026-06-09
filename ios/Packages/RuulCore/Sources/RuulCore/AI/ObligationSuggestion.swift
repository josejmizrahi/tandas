import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// R.6.AI.10 — Estructura `@Generable` que el modelo llena para sugerir un
/// compromiso/obligation de acción. Ej: "Aaron debe entregar el reporte el
/// viernes", "Maria tiene que aprobar el gasto", "Moshe se compromete a
/// llevar el postre el sábado".
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct ObligationSuggestion: Sendable, Equatable {
    @Guide(description: "Nombre EXACTO (de la lista de miembros) del deudor / quien se compromete a hacer la tarea. Si el usuario dice 'yo me comprometo', cadena vacía.")
    public let debtorName: String

    @Guide(description: "Título corto del compromiso en español, 3-8 palabras imperativo. Ejemplos: 'Entregar reporte mensual', 'Aprobar el gasto del palco', 'Llevar el postre el sábado'.")
    public let title: String

    @Guide(description: "Notas adicionales en español, máximo 1-2 oraciones. Cadena vacía si el título ya basta.")
    public let detail: String

    @Guide(description: "Tipo canónico del compromiso. Valores: action (genérico, default), approval (necesita aprobar algo), delivery (entregar algo físico o digital), attendance (asistir a un lugar/evento), document (firmar o subir documento), reservation (reservar algo), custom (otro).")
    public let kindKey: String

    @Guide(description: "true si el usuario menciona una fecha límite (mañana, viernes, en 3 días, etc.). false si no especifica fecha.")
    public let hasDueDate: Bool

    @Guide(description: "Frase corta en español resumiendo qué entendiste del compromiso.")
    public let rationale: String
}
#endif
