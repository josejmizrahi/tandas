import Foundation
import Testing
@testable import RuulCore

@Suite("NotificationPreference + GroupVisibility domain")
struct NotificationPreferenceDomainTests {

    @Test("NotificationPreferenceRow decodes the canonical wire shape")
    func decodesRow() throws {
        let gid = UUID()
        let json = """
        {
          "group_id":   "\(gid.uuidString)",
          "category":   "decisions",
          "channel":    "push",
          "enabled":    false,
          "updated_at": null
        }
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(NotificationPreferenceRow.self, from: json)
        #expect(row.groupId == gid)
        #expect(row.category == "decisions")
        #expect(row.channel == "push")
        #expect(row.enabled == false)
        #expect(row.lookupKey == "decisions:push")
    }

    @Test("Static lookupKey matches row instance key")
    func lookupKeyMatches() {
        let key = NotificationPreferenceRow.lookupKey(category: .sanctions, channel: .inApp)
        #expect(key == "sanctions:in_app")
    }

    @Test("Channel.userSelectable hides email + sms (no infra yet)")
    func channelUserSelectable() {
        let kinds = NotificationChannel.userSelectable
        #expect(kinds.contains(.push))
        #expect(kinds.contains(.inApp))
        #expect(kinds.contains(.email) == false)
        #expect(kinds.contains(.sms) == false)
    }

    @Test("GroupVisibility round-trips through rawValue")
    func visibilityRoundTrip() {
        for v in GroupVisibility.allCases {
            #expect(GroupVisibility(rawValue: v.rawValue) == v)
        }
        #expect(GroupVisibility(rawValue: "future_mode") == nil)
    }
}
