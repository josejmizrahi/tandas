import Foundation
import Testing
@testable import RuulCore

@Suite("MoneyMovement domain")
struct MoneyMovementTests {

    @Test("decodes the canonical row from group_money_movements()")
    func decodesReadShape() throws {
        let tid = UUID(); let gid = UUID()
        let fromMid = UUID(); let toMid = UUID(); let paidByMid = UUID()
        let recBy = UUID()
        let json = """
        {
          "transaction_id":           "\(tid.uuidString)",
          "seq":                      42,
          "group_id":                 "\(gid.uuidString)",
          "transaction_type":         "expense",
          "amount":                   "150.0000",
          "unit":                     "MXN",
          "from_membership_id":       "\(fromMid.uuidString)",
          "from_display_name":        "Ana López",
          "to_membership_id":         "\(toMid.uuidString)",
          "to_display_name":          "Mateo García",
          "paid_by_membership_id":    "\(paidByMid.uuidString)",
          "paid_by_display_name":     "Ana López",
          "recorded_by_user_id":      "\(recBy.uuidString)",
          "recorded_by_display_name": "Ana López",
          "source_entity_kind":       "manual",
          "source_entity_id":         null,
          "source_resource_id":       null,
          "resource_id":              null,
          "reversed_entry_id":        null,
          "in_kind":                  false,
          "split_mode":               "even",
          "description":              "Cena del viernes",
          "occurred_at":              null,
          "created_at":               null
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(MoneyMovement.self, from: json)
        #expect(m.id == tid)
        #expect(m.seq == 42)
        #expect(m.type == .expense)
        #expect(m.amount == Decimal(string: "150")!)
        #expect(m.unit == "MXN")
        #expect(m.fromDisplayName == "Ana López")
        #expect(m.toDisplayName == "Mateo García")
        #expect(m.description == "Cena del viernes")
        #expect(m.inKind == false)
        #expect(m.splitMode == "even")
        #expect(m.isReversal == false)
    }

    @Test("unknown transaction_type falls back to .other")
    func tolerantTypeFallback() throws {
        let json = """
        {
          "transaction_id":  "\(UUID().uuidString)",
          "seq":             1,
          "group_id":        "\(UUID().uuidString)",
          "transaction_type":"future_flow_we_dont_know_yet",
          "amount":          "1.0",
          "unit":            "MXN",
          "in_kind":         false
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(MoneyMovement.self, from: json)
        #expect(m.type == .other)
    }

    @Test("amount accepts numeric or string")
    func tolerantAmountDecode() throws {
        let json = """
        {
          "transaction_id":  "\(UUID().uuidString)",
          "seq":             7,
          "group_id":        "\(UUID().uuidString)",
          "transaction_type":"settlement_payment",
          "amount":          250,
          "unit":            "MXN",
          "in_kind":         false
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(MoneyMovement.self, from: json)
        #expect(m.amount == Decimal(string: "250")!)
        #expect(m.type == .settlementPayment)
    }

    @Test("mandate_id decodes from group_money_movements row (V2-G5)")
    func mandateIdDecode() throws {
        let mandateId = UUID()
        let json = """
        {
          "transaction_id":   "\(UUID().uuidString)",
          "seq":              9,
          "group_id":         "\(UUID().uuidString)",
          "transaction_type": "expense",
          "amount":           "100",
          "unit":             "MXN",
          "in_kind":          false,
          "mandate_id":       "\(mandateId.uuidString)"
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(MoneyMovement.self, from: json)
        #expect(m.mandateId == mandateId)
    }

    @Test("mandate_id is nil when absent in the row")
    func mandateIdAbsent() throws {
        let json = """
        {
          "transaction_id":   "\(UUID().uuidString)",
          "seq":              10,
          "group_id":         "\(UUID().uuidString)",
          "transaction_type": "settlement_payment",
          "amount":           "50",
          "unit":             "MXN",
          "in_kind":          false
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(MoneyMovement.self, from: json)
        #expect(m.mandateId == nil)
    }

    @Test("reversed_entry_id flips isReversal")
    func reversalHint() throws {
        let json = """
        {
          "transaction_id":   "\(UUID().uuidString)",
          "seq":              5,
          "group_id":         "\(UUID().uuidString)",
          "transaction_type": "reversal",
          "amount":           "10",
          "unit":             "MXN",
          "reversed_entry_id":"\(UUID().uuidString)",
          "in_kind":          false
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(MoneyMovement.self, from: json)
        #expect(m.isReversal == true)
    }
}
