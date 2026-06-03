import Testing
import Foundation
@testable import RuulCore

/// Tests del ruteo de URLs entrantes (universal links + scheme ruul://).
@Suite("DeepLinkRouter")
struct DeepLinkTests {

    @Test("Parsea universal links de invitación")
    func universalLink() {
        #expect(DeepLinkRouter.inviteCode(from: URL(string: "https://ruul.mx/invite/AB12CD34")!) == "AB12CD34")
        #expect(DeepLinkRouter.inviteCode(from: URL(string: "https://ruul.app/invite/ab12cd34")!) == "ab12cd34")
    }

    @Test("Parsea el scheme ruul://")
    func customScheme() {
        #expect(DeepLinkRouter.inviteCode(from: URL(string: "ruul://invite/AB12CD34")!) == "AB12CD34")
    }

    @Test("Rechaza URLs que no son de invitación")
    func rejectsOthers() {
        #expect(DeepLinkRouter.inviteCode(from: URL(string: "https://ruul.mx/")!) == nil)
        #expect(DeepLinkRouter.inviteCode(from: URL(string: "https://ruul.mx/invite/")!) == nil)
        #expect(DeepLinkRouter.inviteCode(from: URL(string: "https://ruul.mx/group/abc")!) == nil)
        #expect(DeepLinkRouter.inviteCode(from: URL(string: "ruul://other/abc")!) == nil)
        #expect(DeepLinkRouter.inviteCode(from: URL(string: "mailto:hola@ruul.mx")!) == nil)
    }

    @Test("El router guarda y consume el código pendiente")
    @MainActor
    func pendingFlow() {
        let router = DeepLinkRouter()

        #expect(router.handle(URL(string: "https://ruul.mx/invite/XYZ789")!))
        #expect(router.pendingInviteCode == "XYZ789")

        #expect(router.consumePendingInviteCode() == "XYZ789")
        #expect(router.pendingInviteCode == nil)

        // URL no reconocida no deja estado pendiente.
        #expect(!router.handle(URL(string: "https://ruul.mx/legal/terms")!))
        #expect(router.pendingInviteCode == nil)
    }
}
