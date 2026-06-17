import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// D.CATALOG.B (founder Flow #10.c, 2026-06-09) — Shape `@Generable` que el
/// modelo on-device llena al subir un documento. Sugiere `documentType` del
/// catalog canónico (R.12.G CHECK constraint) y `title` derivado del
/// nombre/descripción del archivo.
///
/// Doctrina founder AI: el modelo PROPONE, NUNCA ejecuta. El user confirma
/// "Aplicar" antes de que se llenen los `@State` del form manual.
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct DocumentSuggestion: Sendable, Equatable {
    @Guide(description: "Tipo del documento. Valores válidos EXACTOS: contract, receipt, id, statement, photo, other, policy, certificate. Elige el más apropiado según la descripción.")
    public let documentType: String

    @Guide(description: "Título corto del documento en español, máximo 8 palabras. Útil para identificarlo en la lista del espacio.")
    public let title: String

    @Guide(description: "Una frase corta en español explicando por qué elegiste ese tipo de documento.")
    public let rationale: String
}
#endif
