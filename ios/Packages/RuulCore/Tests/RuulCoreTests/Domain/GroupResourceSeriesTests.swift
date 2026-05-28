import Foundation
import Testing
@testable import RuulCore

@Suite("GroupResourceSeries domain")
struct GroupResourceSeriesTests {

    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    @Test("Decodes the wire row with bare ISO dates for starts_on / ends_on")
    func decodesWithDateOnly() throws {
        let sid = UUID(); let gid = UUID()
        let json = """
        {
          "series_id":                "\(sid.uuidString)",
          "group_id":                 "\(gid.uuidString)",
          "resource_type":            "event",
          "cadence":                  "weekly",
          "pattern":                  {"day_of_week":"thursday"},
          "starts_on":                "2026-05-28",
          "ends_on":                  null,
          "ritual_meaning":           "Cena de los jueves",
          "ritual_marker_kind":       "weekly_meeting",
          "ritual_norm_id":           null,
          "template_payload":         {},
          "created_by":               null,
          "created_by_display_name":  "Jose",
          "created_at":               null,
          "updated_at":               null
        }
        """.data(using: .utf8)!
        let s = try makeDecoder().decode(GroupResourceSeries.self, from: json)
        #expect(s.id == sid)
        #expect(s.cadence == .weekly)
        #expect(s.ritualMarkerKind == .weeklyMeeting)
        #expect(s.ritualMeaning == "Cena de los jueves")
        #expect(s.startsOn != nil)
        #expect(s.endsOn == nil)
        #expect(s.isRitual)
    }

    @Test("Unknown cadence + marker fall back to safe defaults")
    func decodesUnknownEnums() throws {
        let json = """
        {
          "series_id": "\(UUID().uuidString)",
          "group_id":  "\(UUID().uuidString)",
          "resource_type": "event",
          "cadence":   "future_cadence",
          "ritual_meaning": null,
          "ritual_marker_kind": "future_marker"
        }
        """.data(using: .utf8)!
        let s = try makeDecoder().decode(GroupResourceSeries.self, from: json)
        #expect(s.cadence == .custom)
        #expect(s.ritualMarkerKind == RitualMarkerKind.none)
        // No meaning + marker kind .none ⇒ not a ritual.
        #expect(s.isRitual == false)
    }

    @Test("Selectable kinds exclude .none from picker")
    func selectableSkipsNone() {
        let kinds = RitualMarkerKind.selectable
        #expect(kinds.contains(.weeklyMeeting))
        #expect(kinds.contains(.celebration))
        #expect(kinds.contains(.none) == false)
    }
}
