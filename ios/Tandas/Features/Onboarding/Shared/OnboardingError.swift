import Foundation

enum OnboardingError: LocalizedError, Equatable {
    case createGroupFailed(String)
    case updateGroupFailed(String)
    case createRulesFailed(String)
    case createInviteFailed(String)
    case otpSendFailed(String)
    case otpVerifyFailed(reason: String, attempts: Int)
    case otpTooManyAttempts
    case inviteCodeInvalid
    case inviteCodeExpired
    case markInviteUsedFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .createGroupFailed:
            return "No pudimos crear el grupo. Intenta de nuevo."
        case .updateGroupFailed:
            return "No se pudo guardar la configuración."
        case .createRulesFailed:
            return "No pudimos crear las reglas."
        case .createInviteFailed:
            return "No se pudo enviar la invitación."
        case .otpSendFailed:
            return "No pudimos enviar el código. Intenta de nuevo."
        case .otpVerifyFailed:
            return "Código incorrecto."
        case .otpTooManyAttempts:
            return "Demasiados intentos fallidos. Pide un código nuevo."
        case .inviteCodeInvalid:
            return "Esta invitación ya no es válida. Pídele a tu amigo que te mande una nueva."
        case .inviteCodeExpired:
            return "Esta invitación expiró."
        case .markInviteUsedFailed:
            return "No pudimos confirmar tu invitación."
        case .unknown(let msg):
            return msg
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .inviteCodeInvalid, .inviteCodeExpired: return false
        default: return true
        }
    }
}
