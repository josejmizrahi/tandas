import Foundation

/// Maps raw backend resource status strings to Spanish UI labels.
///
/// Backend stores statuses as English lowercase identifiers
/// (`"active"`, `"locked"`, `"expired"`, …). Builders previously
/// surfaced these via `String.capitalized`, leaking English into
/// Identity subtitles, hero headlines, and PropertiesBlock rows
/// ("Activo · Active", "Estado: Active", a giant "Active" hero).
///
/// All universal-detail builders now route status strings through
/// this helper so the UI reads as Spanish throughout.
enum ResourceStatusLocalization {
    /// Returns the Spanish UI label for a raw backend status string.
    /// Falls back to `raw.capitalized` for any unmapped value so new
    /// statuses surface visibly rather than disappearing.
    static func es(_ raw: String) -> String {
        switch raw.lowercased() {
        case "active":     return "Activo"
        case "inactive":   return "Inactivo"
        case "expired":    return "Expirado"
        case "revoked":    return "Revocado"
        case "locked":     return "Bloqueado"
        case "unlocked":   return "Activo"
        case "closed":     return "Cerrado"
        case "open":       return "Abierto"
        case "pending":    return "Pendiente"
        case "completed":  return "Completado"
        case "draft":      return "Borrador"
        case "archived":   return "Archivado"
        case "cancelled",
             "canceled":   return "Cancelado"
        default:           return raw.capitalized
        }
    }
}
