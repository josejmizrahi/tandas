import Foundation
import CryptoKit

/// HMAC-SHA256 signing/verification for check-in QR payloads.
///
/// Format: `<eventId>:<memberId>:<base64url(HMAC(secret, "eventId:memberId"))>`
///
/// V1: shared secret between client and server (in
/// `Tandas.local.xcconfig` as `RUUL_QR_SECRET` and Supabase secret).
/// V2 upgrade path: server-only verification, client posts payload to
/// edge function for validation. See Plans/EventLayerV1.md §13.6.
enum QRSignatureService {
    /// Build a signed payload string for an event + member.
    static func sign(eventId: UUID, memberId: UUID, secret: String) -> String {
        let body = "\(eventId.uuidString.lowercased()):\(memberId.uuidString.lowercased())"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        let sigB64 = Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(body):\(sigB64)"
    }

    /// Returns nil if payload is malformed or signature doesn't verify.
    static func verify(_ payload: String, secret: String) -> (eventId: UUID, memberId: UUID)? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let eventId = UUID(uuidString: parts[0]),
              let memberId = UUID(uuidString: parts[1])
        else { return nil }
        let expected = sign(eventId: eventId, memberId: memberId, secret: secret)
        // Constant-time comparison to avoid timing side-channels.
        guard expected.count == payload.count,
              expected.utf8.elementsEqual(payload.utf8)
        else { return nil }
        return (eventId, memberId)
    }

    /// Reads the shared secret from Info.plist (injected via xcconfig).
    /// Returns empty string if missing — sign/verify still works for tests.
    static var sharedSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "RuulQRSecret") as? String ?? ""
    }
}
