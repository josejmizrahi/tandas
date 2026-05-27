import Foundation

/// Human copy for errors. Features should never display raw `PostgrestError`
/// or backend regex messages — always route through here.
public struct UserFacingError: Sendable, Equatable {
    public let title: String
    public let message: String

    public init(title: String = "Algo salió mal", message: String) {
        self.title = title
        self.message = message
    }

    /// Best-effort mapping from any `Error` to a Spanish, user-readable
    /// message. Recognises `RuulError` cases explicitly; falls back to a
    /// generic line for anything else.
    public static func from(_ error: any Error) -> UserFacingError {
        if let ruul = error as? RuulError {
            return from(ruul)
        }
        return UserFacingError(message: "Algo salió mal. Vuelve a intentar.")
    }

    public static func from(_ ruul: RuulError) -> UserFacingError {
        switch ruul {
        case .backend(let inner): return from(inner)
        case .network: return UserFacingError(title: "Sin conexión", message: "Revisa tu internet y vuelve a intentar.")
        case .decoding: return UserFacingError(message: "Recibimos algo inesperado. Vuelve a intentar.")
        case .cancelled: return UserFacingError(message: "Cancelado.")
        case .unexpected(let m): return UserFacingError(message: m)
        }
    }

    public static func from(_ backend: CanonicalBackendError) -> UserFacingError {
        switch backend {
        case .mustBeAuthenticated:
            return UserFacingError(title: "Inicia sesión", message: "Tu sesión venció. Vuelve a entrar.")
        case .callerNotActiveMember:
            return UserFacingError(message: "Ya no eres miembro activo de este grupo.")
        case .lacksPermission(let permission, _):
            return UserFacingError(title: "Sin permiso", message: "No puedes hacer esto en este grupo (\(permission)).")
        case .amountMustBePositive, .amountRequired:
            return UserFacingError(message: "El monto debe ser mayor a cero.")
        case .customSplitMismatch:
            return UserFacingError(message: "La suma del reparto no cuadra con el monto.")
        case .invalidPaidToKind:
            return UserFacingError(message: "Destino del pago inválido.")
        case .resourceNotInGroup:
            return UserFacingError(message: "Ese recurso no pertenece a este grupo.")
        case .crossTenantViolation:
            return UserFacingError(message: "Operación inválida entre grupos.")
        case .inviteRequiresEmailOrPhone:
            return UserFacingError(message: "Necesitas un correo o teléfono para invitar.")
        case .inviteNotFoundOrUsed:
            return UserFacingError(title: "Invitación inválida", message: "El código ya fue usado o no existe.")
        case .inviteExpired:
            return UserFacingError(title: "Invitación expirada", message: "Pídeles que generen una nueva.")
        case .inviteTokenMismatch:
            return UserFacingError(title: "Invitación inválida", message: "El código no coincide.")
        case .mandateDoesNotAuthorize(let reason):
            let detail = reason ?? "el mandato no cubre esta acción"
            return UserFacingError(title: "Sin autoridad delegada", message: detail)
        case .ruleEvaluationDepthExceeded:
            return UserFacingError(message: "Las reglas del grupo se ciclaron. Avísale al admin.")
        case .displayNameRequired:
            return UserFacingError(message: "Escribe tu nombre.")
        case .usernameAlreadyTaken:
            return UserFacingError(title: "Usuario ocupado", message: "Ese usuario ya está ocupado.")
        case .invalidPurposeKind:
            return UserFacingError(message: "Tipo de propósito inválido.")
        case .invalidPurposeVisibility:
            return UserFacingError(message: "Visibilidad inválida.")
        case .purposeBodyRequired:
            return UserFacingError(message: "Escribe el propósito.")
        case .ruleTitleRequired:
            return UserFacingError(message: "Escribe el título de la regla.")
        case .ruleBodyRequired:
            return UserFacingError(message: "Escribe la regla.")
        case .invalidRuleType:
            return UserFacingError(message: "Tipo de regla inválido.")
        case .invalidRuleSeverity:
            return UserFacingError(message: "Severidad inválida (0–5).")
        case .ruleNotFound:
            return UserFacingError(message: "Esa regla ya no existe.")
        case .unknown(let message):
            return UserFacingError(message: message)
        }
    }
}
