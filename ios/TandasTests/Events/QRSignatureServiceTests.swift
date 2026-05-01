import Testing
import Foundation
@testable import Tandas

@Suite("QRSignatureService")
struct QRSignatureServiceTests {
    let secret = "test-secret-32-bytes-of-something-here"

    @Test("sign + verify roundtrip")
    func roundtrip() {
        let eventId = UUID()
        let memberId = UUID()
        let payload = QRSignatureService.sign(eventId: eventId, memberId: memberId, secret: secret)
        let verified = QRSignatureService.verify(payload, secret: secret)
        #expect(verified?.eventId == eventId)
        #expect(verified?.memberId == memberId)
    }

    @Test("tampered payload is rejected")
    func tampered() {
        let payload = QRSignatureService.sign(eventId: UUID(), memberId: UUID(), secret: secret)
        // Flip the last char of the signature.
        let bad = String(payload.dropLast()) + "X"
        #expect(QRSignatureService.verify(bad, secret: secret) == nil)
    }

    @Test("wrong secret is rejected")
    func wrongSecret() {
        let payload = QRSignatureService.sign(eventId: UUID(), memberId: UUID(), secret: secret)
        #expect(QRSignatureService.verify(payload, secret: "different-secret") == nil)
    }

    @Test("malformed payload returns nil")
    func malformed() {
        #expect(QRSignatureService.verify("garbage", secret: secret) == nil)
        #expect(QRSignatureService.verify("a:b:c", secret: secret) == nil)
        #expect(QRSignatureService.verify("", secret: secret) == nil)
    }
}
