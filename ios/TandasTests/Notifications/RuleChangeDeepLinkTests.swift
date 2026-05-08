import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("RuleChangeDeepLink")
struct RuleChangeDeepLinkTests {

    @Test("parses valid URL with proposedAmount")
    func parsesValidUrl() throws {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString)/edit?proposedAmount=350")!
        let link = try #require(RuleChangeDeepLink(url: url))
        #expect(link.ruleId == id)
        #expect(link.proposedAmount == 350)
    }

    @Test("parses valid URL with uppercase UUID")
    func parsesUppercaseUuid() throws {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString.uppercased())/edit?proposedAmount=200")!
        let link = try #require(RuleChangeDeepLink(url: url))
        #expect(link.ruleId == id)
        #expect(link.proposedAmount == 200)
    }

    @Test("returns nil for wrong scheme")
    func rejectsWrongScheme() {
        let url = URL(string: "https://rule/uuid/edit?proposedAmount=100")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for wrong host")
    func rejectsWrongHost() {
        let url = URL(string: "ruul://event/uuid/edit?proposedAmount=100")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for missing edit segment")
    func rejectsMissingEdit() {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString)?proposedAmount=100")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for malformed UUID")
    func rejectsMalformedUuid() {
        let url = URL(string: "ruul://rule/not-a-uuid/edit?proposedAmount=100")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for missing proposedAmount")
    func rejectsMissingAmount() {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString)/edit")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }

    @Test("returns nil for non-integer proposedAmount")
    func rejectsNonIntegerAmount() {
        let id = UUID()
        let url = URL(string: "ruul://rule/\(id.uuidString)/edit?proposedAmount=abc")!
        #expect(RuleChangeDeepLink(url: url) == nil)
    }
}
