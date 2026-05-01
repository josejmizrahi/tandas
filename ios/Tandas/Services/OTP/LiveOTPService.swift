import Foundation
import Supabase

/// Live OTP service that calls the `send-otp` and `verify-otp` Edge Functions.
final class LiveOTPService: OTPService {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func requestCode(phoneE164: String) async throws -> OTPChannel {
        guard phoneE164.hasPrefix("+"), phoneE164.count >= 8 else { throw OTPError.invalidPhone }
        struct Body: Encodable { let phone: String }
        struct Resp: Decodable { let channel: String }

        do {
            let resp: Resp = try await client.functions
                .invoke(
                    "send-otp",
                    options: FunctionInvokeOptions(body: Body(phone: phoneE164))
                )
            guard let channel = OTPChannel(rawValue: resp.channel) else {
                throw OTPError.sendFailed("unknown channel \(resp.channel)")
            }
            return channel
        } catch let e as OTPError {
            throw e
        } catch {
            throw OTPError.network(error.localizedDescription)
        }
    }

    func verifyCode(phoneE164: String, code: String, channel: OTPChannel) async throws {
        struct Body: Encodable {
            let phone: String
            let code: String
            let channel: String
        }
        struct Resp: Decodable {
            let access_token: String
            let refresh_token: String
            let user_id: String?
        }

        do {
            let resp: Resp = try await client.functions
                .invoke(
                    "verify-otp",
                    options: FunctionInvokeOptions(body: Body(
                        phone: phoneE164,
                        code: code,
                        channel: channel.rawValue
                    ))
                )
            try await client.auth.setSession(
                accessToken: resp.access_token,
                refreshToken: resp.refresh_token
            )
        } catch let e as OTPError {
            throw e
        } catch {
            // Edge function 4xx returns are caught here. We can't easily
            // distinguish "invalid code" from "session mint failed" without
            // parsing the error body — for now, surface a generic
            // invalid-code error. The coordinator counts attempts.
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
