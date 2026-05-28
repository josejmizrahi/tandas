import Foundation
import Testing
@testable import RuulCore

@Suite("GroupDecision domain")
struct GroupDecisionTests {

    private let iso = ISO8601DateFormatter()

    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    @Test("GroupDecisionSummary decodes the list row shape")
    func summaryDecodes() throws {
        let id = UUID(); let gid = UUID(); let creator = UUID()
        let json = """
        {
          "decision_id":            "\(id.uuidString)",
          "group_id":               "\(gid.uuidString)",
          "title":                  "¿Subimos cuota?",
          "body":                   "Detalle…",
          "decision_type":          "proposal",
          "method":                 "supermajority",
          "legitimacy_source":      "majority",
          "status":                 "open",
          "threshold_pct":          null,
          "quorum_pct":             null,
          "reference_kind":         null,
          "reference_id":           null,
          "opens_at":               null,
          "closes_at":              null,
          "decided_at":             null,
          "created_at":             null,
          "created_by":             "\(creator.uuidString)",
          "created_by_display_name":"Ana López",
          "option_count":           2,
          "vote_count":             3,
          "yes_count":              2,
          "no_count":               1,
          "abstain_count":          0,
          "block_count":            0,
          "result":                 {},
          "my_vote_value":          "yes",
          "my_vote_option_id":      null
        }
        """.data(using: .utf8)!
        let s = try makeDecoder().decode(GroupDecisionSummary.self, from: json)
        #expect(s.id == id)
        #expect(s.groupId == gid)
        #expect(s.title == "¿Subimos cuota?")
        #expect(s.decisionType == .proposal)
        #expect(s.method == .supermajority)
        #expect(s.status == .open)
        #expect(s.optionCount == 2)
        #expect(s.tally.voteCount == 3)
        #expect(s.tally.yesCount == 2)
        #expect(s.tally.noCount == 1)
        #expect(s.myVoteValue == .yes)
        #expect(s.createdByDisplayName == "Ana López")
    }

    @Test("Unknown method / status / type fall back to safe defaults")
    func summaryFallbacks() throws {
        let json = """
        {
          "decision_id": "\(UUID().uuidString)",
          "group_id":    "\(UUID().uuidString)",
          "title":       "X",
          "decision_type": "future_kind",
          "method":      "ranked_choice",
          "status":      "abandoned",
          "option_count": 0,
          "vote_count":   0,
          "yes_count":    0,
          "no_count":     0,
          "abstain_count":0,
          "block_count":  0
        }
        """.data(using: .utf8)!
        let s = try makeDecoder().decode(GroupDecisionSummary.self, from: json)
        #expect(s.decisionType == .other)
        #expect(s.method == .other)
        #expect(s.status == .open)
    }

    @Test("GroupDecisionDetail decodes options + my_vote + per-option tally")
    func detailDecodes() throws {
        let id = UUID(); let gid = UUID()
        let optA = UUID(); let optB = UUID()
        let json = """
        {
          "decision_id":            "\(id.uuidString)",
          "group_id":               "\(gid.uuidString)",
          "title":                  "Pizza",
          "body":                   null,
          "decision_type":          "proposal",
          "method":                 "majority",
          "legitimacy_source":      "majority",
          "status":                 "passed",
          "threshold_pct":          null,
          "quorum_pct":             null,
          "reference_kind":         null,
          "reference_id":           null,
          "opens_at":               null,
          "closes_at":              null,
          "decided_at":             null,
          "created_at":             null,
          "created_by":             null,
          "created_by_display_name":"Jose",
          "result":                 {"yes":1,"no":0,"abstain":0,"block":0,"outcome":"passed"},
          "options": [
            {"id":"\(optA.uuidString)","label":"Sí","body":null,"sort_order":0},
            {"id":"\(optB.uuidString)","label":"No","body":null,"sort_order":1}
          ],
          "tally": {
            "vote_count": 1,
            "yes_count": 1,
            "no_count": 0,
            "abstain_count": 0,
            "block_count": 0
          },
          "option_tally": {
            "\(optA.uuidString)": 1
          },
          "my_vote": {
            "vote_value": "yes",
            "option_id": null,
            "reason": "smoke",
            "cast_at": null
          }
        }
        """.data(using: .utf8)!
        let d = try makeDecoder().decode(GroupDecisionDetail.self, from: json)
        #expect(d.id == id)
        #expect(d.title == "Pizza")
        #expect(d.options.count == 2)
        #expect(d.options.first?.id == optA)
        #expect(d.tally.yesCount == 1)
        #expect(d.optionTally[optA] == 1)
        #expect(d.optionTally[optB] == nil)
        #expect(d.myVote?.voteValue == .yes)
        #expect(d.myVote?.reason == "smoke")
        #expect(d.result?.outcome == "passed")
        #expect(d.status == .passed)
    }

    @Test("Detail with missing my_vote stays nil")
    func detailMyVoteAbsent() throws {
        let json = """
        {
          "decision_id": "\(UUID().uuidString)",
          "group_id":    "\(UUID().uuidString)",
          "title":       "X",
          "status":      "open",
          "options":     [],
          "tally":       null,
          "option_tally":null,
          "my_vote":     null
        }
        """.data(using: .utf8)!
        let d = try makeDecoder().decode(GroupDecisionDetail.self, from: json)
        #expect(d.myVote == nil)
        #expect(d.options.isEmpty)
        #expect(d.tally.voteCount == 0)
        #expect(d.optionTally.isEmpty)
    }

    @Test("hasMyVote / isOpenForVoting helpers")
    func helpers() {
        let open = GroupDecisionSummary(
            id: UUID(), groupId: UUID(), title: "t",
            status: .open, myVoteValue: .yes
        )
        #expect(open.hasMyVote)
        let closed = GroupDecisionDetail(
            id: UUID(), groupId: UUID(), title: "t",
            status: .passed
        )
        #expect(closed.isOpenForVoting == false)
    }
}
