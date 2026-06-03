import Foundation

/// Errores que los RPCs MVP2 levantan vía `raise exception`. El catálogo de
/// mensajes vive en las migrations `mvp2_*`/`r2*` — el parser reconoce los
/// patrones estables y deja el resto como `.unknown`.
public enum BackendError: Sendable, Equatable {
    /// `unauthenticated` (errcode 28000) — sin sesión o sin person actor.
    case unauthenticated
    /// `not a member of context <uuid>` / `not an active member …` (42501).
    case notAMember
    /// `missing permission <key>` / `not authorized to …` (42501).
    case missingPermission(key: String?)
    /// `amount must be positive`, `currency is required`, splits inválidos… (22023).
    case validation(message: String)
    /// EXCLUDE constraint de reservaciones (23P01) — el rango ya está ocupado.
    case reservationOverlap
    /// `invite …` inválido/expirado/agotado.
    case invalidInvite(message: String)
    /// Cualquier otro raise no catalogado.
    case unknown(message: String)
}

/// Copy en español para mostrar en UI. Las vistas nunca muestran mensajes
/// crudos del backend.
public struct UserFacingError: Sendable, Equatable {
    public let title: String
    public let message: String

    public init(title: String = "Algo salió mal", message: String) {
        self.title = title
        self.message = message
    }

    public static func from(_ error: any Error) -> UserFacingError {
        guard let ruul = error as? RuulError else {
            return UserFacingError(message: "Algo salió mal. Vuelve a intentar.")
        }
        switch ruul {
        case .backend(let backend): return from(backend)
        case .network: return UserFacingError(title: "Sin conexión", message: "Revisa tu internet y vuelve a intentar.")
        case .decoding: return UserFacingError(message: "Recibimos una respuesta inesperada. Vuelve a intentar.")
        case .cancelled: return UserFacingError(message: "Cancelado.")
        case .unexpected(let m): return UserFacingError(message: m)
        }
    }

    public static func from(_ backend: BackendError) -> UserFacingError {
        switch backend {
        case .unauthenticated:
            return UserFacingError(title: "Inicia sesión", message: "Tu sesión venció. Vuelve a entrar.")
        case .notAMember:
            return UserFacingError(message: "No eres miembro de este contexto.")
        case .missingPermission(let key):
            let detail = key.map { " (\($0))" } ?? ""
            return UserFacingError(title: "Sin permiso", message: "No tienes permiso para hacer esto\(detail).")
        case .validation(let message):
            return UserFacingError(message: Self.spanish(forValidation: message))
        case .reservationOverlap:
            return UserFacingError(title: "Fechas ocupadas", message: "Ese rango ya tiene una reservación aprobada.")
        case .invalidInvite:
            return UserFacingError(title: "Invitación inválida", message: "El código no existe, expiró o ya se agotó.")
        case .unknown(let message):
            return UserFacingError(message: message)
        }
    }

    private static func spanish(forValidation raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("amount must be positive") { return "El monto debe ser mayor a cero." }
        if s.contains("currency is required") { return "Falta la moneda." }
        if s.contains("splits must sum to amount") { return "El reparto no suma el total del gasto." }
        if s.contains("duplicate participant") { return "Hay un participante repetido en el reparto." }
        if s.contains("not an active member of the context") { return "Uno de los participantes ya no es miembro del contexto." }
        if s.contains("display_name") || s.contains("title is required") { return "Falta el nombre." }
        if s.contains("invalid") { return "Hay un dato inválido: \(raw)" }
        return raw
    }
}

extension RuulError {
    /// Mensaje listo para UI.
    public var userMessage: String { UserFacingError.from(self).message }
}
