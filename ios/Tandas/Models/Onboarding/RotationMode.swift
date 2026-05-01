import Foundation

enum RotationMode: String, Codable, Sendable, Hashable, CaseIterable {
    case autoOrder = "auto_order"
    case manual    = "manual"
    case noHost    = "no_host"

    var displayName: String {
        switch self {
        case .autoOrder: return "Sí, en orden"
        case .manual:    return "Sí, manual"
        case .noHost:    return "No hay anfitrión"
        }
    }

    var description: String {
        switch self {
        case .autoOrder: return "Rotación automática por orden de llegada al grupo."
        case .manual:    return "Asignas el anfitrión manualmente cada evento."
        case .noHost:    return "Eventos sin anfitrión asignado."
        }
    }
}
