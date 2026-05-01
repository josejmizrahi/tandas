import Testing
import Foundation
@testable import Tandas

@Suite("PhoneFormatter")
struct PhoneFormatterTests {
    @Test("digitsOnly strips non-digits")
    func digitsOnly() {
        #expect(PhoneFormatter.digitsOnly("+52 (55) 5555-5555") == "525555555555")
    }

    @Test("e164 builds + dial + digits")
    func buildE164() {
        #expect(PhoneFormatter.e164(dialCode: "52", rawInput: "55 5555 5555") == "+525555555555")
        #expect(PhoneFormatter.e164(dialCode: "1", rawInput: "  ") == nil)
    }

    @Test("smartE164 keeps + prefix as-is")
    func smartKeepsPrefix() {
        #expect(PhoneFormatter.smartE164("+15555551234") == "+15555551234")
    }

    @Test("smartE164 prepends MX when no prefix")
    func smartPrepends() {
        #expect(PhoneFormatter.smartE164("5555551234") == "+525555551234")
    }
}

@Suite("InviteLinkGenerator")
struct InviteLinkGeneratorTests {
    @Test("custom scheme URL")
    func customScheme() {
        let url = InviteLinkGenerator.customScheme(code: "abc123")
        #expect(url.absoluteString == "ruul://invite/abc123")
    }

    @Test("universal URL")
    func universal() {
        let url = InviteLinkGenerator.universal(code: "abc123")
        #expect(url.absoluteString == "https://ruul.app/invite/abc123")
    }

    @Test("share message includes group name and link")
    func shareMessage() {
        let msg = InviteLinkGenerator.shareMessage(groupName: "Los Cuates", code: "xyz")
        #expect(msg.contains("Los Cuates"))
        #expect(msg.contains("https://ruul.app/invite/xyz"))
    }

    @Test("parseInviteCode extracts from custom scheme")
    func parseCustomScheme() {
        let url = URL(string: "ruul://invite/abc12345")!
        #expect(InviteLinkGenerator.parseInviteCode(from: url) == "abc12345")
    }

    @Test("parseInviteCode extracts from https url")
    func parseHTTPS() {
        let url = URL(string: "https://ruul.app/invite/xyz")!
        #expect(InviteLinkGenerator.parseInviteCode(from: url) == "xyz")
    }

    @Test("parseInviteCode rejects other URLs")
    func rejectsOthers() {
        let url = URL(string: "https://example.com/foo")!
        #expect(InviteLinkGenerator.parseInviteCode(from: url) == nil)
    }
}
