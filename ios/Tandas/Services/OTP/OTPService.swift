import Foundation

enum OTPChannel: String, Codable, Sendable, Hashable { case whatsapp, sms }

enum OTPError: Error, Equatable {
    case invalidPhone
    case sendFailed(String)
    case invalidCode
    case tooManyAttempts
    case sessionMintFailed     // verify-otp returned 503; client should retry SMS
    case network(String)
}

protocol OTPService: Sendable {
    /// Returns the channel actually used (WhatsApp falls back to SMS if Wassenger
    /// isn't configured, times out, or errors out).
    func requestCode(phoneE164: String) async throws -> OTPChannel

    /// On success, also installs the session on the SupabaseClient.
    func verifyCode(phoneE164: String, code: String, channel: OTPChannel) async throws
}
