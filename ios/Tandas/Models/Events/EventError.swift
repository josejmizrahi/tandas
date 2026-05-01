import Foundation

enum EventError: LocalizedError, Equatable {
    case createFailed(String)
    case updateFailed(String)
    case cancelFailed(String)
    case closeFailed(String)
    case fetchFailed(String)
    case rsvpFailed(String)
    case checkInFailed(String)
    case alreadyCheckedIn
    case notHost
    case invalidQR
    case notFound

    var errorDescription: String? {
        switch self {
        case .createFailed:    return "No se pudo crear el evento. Reintenta."
        case .updateFailed:    return "No se pudieron guardar los cambios."
        case .cancelFailed:    return "No se pudo cancelar el evento."
        case .closeFailed:     return "No se pudo cerrar el evento."
        case .fetchFailed:     return "No se pudo cargar la información."
        case .rsvpFailed:      return "No se pudo guardar tu RSVP."
        case .checkInFailed:   return "No se pudo registrar la llegada."
        case .alreadyCheckedIn:return "Ya marcaste tu llegada."
        case .notHost:         return "Solo el host puede hacer esto."
        case .invalidQR:       return "QR inválido o ya usado."
        case .notFound:        return "Evento no encontrado."
        }
    }
}
