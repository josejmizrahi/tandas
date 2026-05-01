import Testing
import Foundation
@testable import Tandas

@Suite("EventDeepLink")
struct EventDeepLinkTests {
    @Test("custom scheme parses")
    func customScheme() {
        let id = UUID()
        let url = URL(string: "ruul://event/\(id.uuidString)")!
        let link = EventDeepLink(url: url)
        #expect(link?.eventId == id)
    }

    @Test("https url parses")
    func httpsURL() {
        let id = UUID()
        let url = URL(string: "https://ruul.app/event/\(id.uuidString)")!
        let link = EventDeepLink(url: url)
        #expect(link?.eventId == id)
    }

    @Test("invalid URL returns nil")
    func invalidURL() {
        #expect(EventDeepLink(url: URL(string: "https://example.com/foo")!) == nil)
        #expect(EventDeepLink(url: URL(string: "ruul://invite/abc")!) == nil)
    }

    @Test("userInfo roundtrip")
    func userInfoRoundtrip() {
        let id = UUID()
        let original = EventDeepLink(eventId: id)
        let parsed = EventDeepLink(userInfo: original.userInfo)
        #expect(parsed?.eventId == id)
    }
}
