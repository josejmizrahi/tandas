import Testing
import Foundation
import RuulCore
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

    @Test("universal URL points at canonical ruul.mx")
    func universal() {
        let url = InviteLinkGenerator.universal(code: "abc123")
        #expect(url.absoluteString == "https://ruul.mx/invite/abc123")
    }

    @Test("share message includes group name and plaintext code (no dead URL)")
    func shareMessage() {
        // Beta 1 W1-5: shareMessage must NOT carry the universal
        // https URL — AASA may not be live in all environments, so
        // that link opens Safari to a 404 and the invitee abandons.
        // Plaintext code is the primary affordance; recipient opens
        // the app and pastes it into JoinGroupSheet.
        let msg = InviteLinkGenerator.shareMessage(groupName: "Los Cuates", code: "xyz")
        #expect(msg.contains("Los Cuates"))
        #expect(msg.uppercased().contains("XYZ"), "code must appear in plaintext")
        #expect(msg.localizedCaseInsensitiveContains("código"), "must label the code clearly")
        #expect(!msg.contains("https://"), "must not ship any broken universal link in share body")
        #expect(!msg.contains("http://"), "must not ship any dead http URL")
    }

    @Test("share message uppercases the code so it's easy to copy")
    func shareMessageUppercases() {
        let msg = InviteLinkGenerator.shareMessage(groupName: "G", code: "abc123")
        #expect(msg.contains("ABC123"))
    }

    @Test("parseInviteCode extracts from custom scheme")
    func parseCustomScheme() {
        let url = URL(string: "ruul://invite/abc12345")!
        #expect(InviteLinkGenerator.parseInviteCode(from: url) == "abc12345")
    }

    @Test("parseInviteCode extracts from canonical https url (ruul.mx)")
    func parseHTTPS_canonical() {
        let url = URL(string: "https://ruul.mx/invite/xyz")!
        #expect(InviteLinkGenerator.parseInviteCode(from: url) == "xyz")
    }

    @Test("parseInviteCode still extracts from legacy ruul.app url")
    func parseHTTPS_legacy() {
        // Whitelisted via RuulDomain.acceptedHosts so old WhatsApp
        // messages keep working post-cutover.
        let url = URL(string: "https://ruul.app/invite/xyz")!
        #expect(InviteLinkGenerator.parseInviteCode(from: url) == "xyz")
    }

    @Test("parseInviteCode rejects other URLs")
    func rejectsOthers() {
        let url = URL(string: "https://example.com/foo")!
        #expect(InviteLinkGenerator.parseInviteCode(from: url) == nil)
    }
}
