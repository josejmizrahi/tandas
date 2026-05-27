import Foundation
import Testing
@testable import RuulCore

@Suite("GroupSanction domain")
struct GroupSanctionTests {

    @Test("decodes the canonical row from group_sanctions_active()")
    func decodesReadShape() throws {
        let sid = UUID(); let gid = UUID(); let mid = UUID()
        let json = """
        {
          "sanction_id":             "\(sid.uuidString)",
          "group_id":                "\(gid.uuidString)",
          "target_membership_id":    "\(mid.uuidString)",
          "target_display_name":     "Ana López",
          "issued_by_membership_id": null,
          "issued_by_display_name":  null,
          "sanction_kind":           "monetary",
          "status":                  "active",
          "amount":                  "500.00",
          "unit":                    "MXN",
          "reason":                  "No llegó a la cena.",
          "starts_at":               null,
          "ends_at":                 null,
          "obligation_id":           null,
          "dispute_id":              null,
          "created_at":              null
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(GroupSanction.self, from: json)
        #expect(s.id == sid)
        #expect(s.kind == .monetary)
        #expect(s.amount == Decimal(string: "500.00"))
        #expect(s.unit == "MXN")
        #expect(s.targetDisplayName == "Ana López")
        #expect(s.isMonetary)
        #expect(s.isDisputed == false)
    }

    @Test("unknown kind/status fall back to .other / .active")
    func enumFallbacks() throws {
        let json = """
        {
          "sanction_id":          "\(UUID().uuidString)",
          "group_id":             "\(UUID().uuidString)",
          "target_membership_id": "\(UUID().uuidString)",
          "target_display_name":  "X",
          "sanction_kind":        "future_kind",
          "status":               "future_status",
          "reason":               "?"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(GroupSanction.self, from: json)
        #expect(s.kind == .other)
        #expect(s.status == .active)
    }

    @Test("foundationIssuable excludes heavyweight kinds")
    func foundationIssuableExcludesHeavy() {
        let issuable = Set(SanctionKind.foundationIssuable)
        #expect(issuable.contains(.warning))
        #expect(issuable.contains(.monetary))
        #expect(issuable.contains(.repairTask))
        #expect(issuable.contains(.reputationNote))
        #expect(issuable.contains(.other))
        #expect(issuable.contains(.suspension) == false)
        #expect(issuable.contains(.lossOfRole) == false)
        #expect(issuable.contains(.expulsion) == false)
    }

    @Test("requiresAmount is true only for .monetary")
    func requiresAmountSemantics() {
        #expect(SanctionKind.monetary.requiresAmount)
        for kind in SanctionKind.allCases where kind != .monetary {
            #expect(kind.requiresAmount == false)
        }
    }

    @Test("status isOpen excludes resolved states")
    func statusIsOpen() {
        #expect(SanctionStatus.proposed.isOpen)
        #expect(SanctionStatus.active.isOpen)
        #expect(SanctionStatus.disputed.isOpen)
        #expect(SanctionStatus.reversed.isOpen == false)
        #expect(SanctionStatus.completed.isOpen == false)
        #expect(SanctionStatus.cancelled.isOpen == false)
    }
}
