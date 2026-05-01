import Foundation
import Supabase

/// Live OTP service. Two paths:
///
/// **WhatsApp** (preferred when Wassenger is configured): goes through our
/// `send-otp` + `verify-otp` Edge Functions. The verify path **promotes**
/// the calling anonymous user to phone-authenticated, keeping the same
/// auth.users.id so the founder's group ownership stays intact.
///
/// **SMS** (fallback when Wassenger isn't available or fails): uses Supabase
/// Auth's canonical phone-change flow directly from the client:
/// `auth.updateUser(.init(phone:)) → auth.verifyOtp(type: .phoneChange)`.
/// That flow natively promotes anon → phone with the same UID.
///
/// After a successful WhatsApp verify, we call `auth.refreshSession()` so the
/// JWT picks up the new `is_anonymous: false` claim.
final class LiveOTPService: OTPService {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func requestCode(phoneE164: String) async throws -> OTPChannel {
        guard phoneE164.hasPrefix("+"), phoneE164.count >= 8 else {
            throw OTPError.invalidPhone
        }

        // Try WhatsApp first via our edge function. If it 503's
        // (wassenger_unconfigured) or any other failure, fall through to
        // the client-side SMS path.
        do {
            return try await requestWhatsApp(phoneE164: phoneE164)
        } catch {
            // Fall through; SMS path below.
        }
        return try await requestSMS(phoneE164: phoneE164)
    }

    func verifyCode(phoneE164: String, code: String, channel: OTPChannel) async throws {
        switch channel {
        case .whatsapp:
            try await verifyWhatsApp(phoneE164: phoneE164, code: code)
        case .sms:
            try await verifySMS(phoneE164: phoneE164, code: code)
        }
    }

    // MARK: - WhatsApp (via Edge Functions + admin promote)

    private func requestWhatsApp(phoneE164: String) async throws -> OTPChannel {
        struct Body: Encodable { let phone: String }
        struct Resp: Decodable { let channel: String }
        let resp: Resp = try await client.functions.invoke(
            "send-otp",
            options: FunctionInvokeOptions(body: Body(phone: phoneE164))
        )
        guard resp.channel == "whatsapp" else {
            throw OTPError.sendFailed("unexpected channel: \(resp.channel)")
        }
        return .whatsapp
    }

    private func verifyWhatsApp(phoneE164: String, code: String) async throws {
        struct Body: Encodable {
            let phone: String
            let code: String
        }
        do {
            // Edge function reads the caller JWT from the Authorization
            // header (supabase-swift attaches it automatically), validates
            // the code, then admin.updateUserById to promote the anon
            // caller → phone-authenticated user with the SAME UID.
            _ = try await client.functions.invoke(
                "verify-otp",
                options: FunctionInvokeOptions(body: Body(phone: phoneE164, code: code))
            ) as RawJSONResponse

            // Promotion happened server-side. Refresh the local session so
            // the JWT picks up the new is_anonymous: false claim.
            _ = try await client.auth.refreshSession()
        } catch {
            // Edge function 4xx → invalid code. The coordinator counts
            // attempts and decides the next step (retry, error, etc.).
            throw OTPError.invalidCode
        }
    }

    // MARK: - SMS (via Supabase Auth phone-change flow, client-side)

    private func requestSMS(phoneE164: String) async throws -> OTPChannel {
        // Trigger SMS via Supabase's Twilio integration. Because we use
        // updateUser instead of signInWithOtp, the resulting verify is a
        // 'phone_change' that promotes the current (anon) session in-place.
        do {
            _ = try await client.auth.update(user: UserAttributes(phone: phoneE164))
            return .sms
        } catch {
            throw OTPError.sendFailed(error.localizedDescription)
        }
    }

    private func verifySMS(phoneE164: String, code: String) async throws {
        do {
            // .phoneChange tells Supabase Auth this is the second half of an
            // updateUser({phone}) flow. Anon caller is promoted; new claims
            // are issued; SDK refreshes the session automatically.
            try await client.auth.verifyOTP(
                phone: phoneE164,
                token: code,
                type: .phoneChange
            )
        } catch {
            throw OTPError.invalidCode
        }
    }
}

/// Mock for tests / previews.
final class MockOTPService: OTPService, @unchecked Sendable {
    var requestResult: Result<OTPChannel, OTPError> = .success(.whatsapp)
    var verifyResult: Result<Void, OTPError> = .success(())
    private(set) var requestCalls: [String] = []
    private(set) var verifyCalls: [(String, String, OTPChannel)] = []

    func requestCode(phoneE164: String) async throws -> OTPChannel {
        requestCalls.append(phoneE164)
        switch requestResult {
        case .success(let ch): return ch
        case .failure(let e):  throw e
        }
    }

    func verifyCode(phoneE164: String, code: String, channel: OTPChannel) async throws {
        verifyCalls.append((phoneE164, code, channel))
        switch verifyResult {
        case .success: return
        case .failure(let e): throw e
        }
    }
}

/// Internal — used to discard the verify-otp body when we only care about
/// success vs failure. The edge function returns { ok, user_id, promoted }
/// but the client doesn't need any of it (refreshSession picks up the
/// promotion).
private struct RawJSONResponse: Decodable {
    let ok: Bool?
}
