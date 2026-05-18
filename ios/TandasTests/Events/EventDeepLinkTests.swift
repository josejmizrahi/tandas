import Testing
import Foundation
import RuulCore
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

    @Test("https url parses on canonical host (ruul.mx)")
    func httpsURL_canonical() {
        let id = UUID()
        let url = URL(string: "https://ruul.mx/event/\(id.uuidString)")!
        let link = EventDeepLink(url: url)
        #expect(link?.eventId == id)
    }

    @Test("https url still parses on legacy host (ruul.app)")
    func httpsURL_legacy() {
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
