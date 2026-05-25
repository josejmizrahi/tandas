import Testing
import Foundation
import RuulCore
@testable import Tandas

@Suite("LedgerEntry+Metadata")
struct LedgerEntryMetadataTests {

    // MARK: - Fixtures

    private static let memberA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let memberB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let memberC = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let resourceX = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    private static func payload(_ pairs: [String: JSONConfig]) -> JSONConfig {
        .object(pairs)
    }

    /// Builds a minimal `LedgerEntry` with the given metadata so the
    /// `LedgerEntry` proxy accessors share the same test surface as the
    /// `JSONConfig` extension.
    private static func entry(metadata: JSONConfig) -> LedgerEntry {
        LedgerEntry(
            groupId: UUID(),
            type: LedgerEntry.Kind.expense,
            amountCents: 10_000,
            metadata: metadata
        )
    }

    // MARK: - note

    @Test("note: returns string when present")
    func notePresent() {
        let p = Self.payload(["note": .string("Cena del viernes")])
        #expect(p.ledgerNote == "Cena del viernes")
    }

    @Test("note: nil when missing")
    func noteMissing() {
        #expect(Self.payload([:]).ledgerNote == nil)
    }

    @Test("note: nil when empty string")
    func noteEmpty() {
        #expect(Self.payload(["note": .string("")]).ledgerNote == nil)
    }

    // MARK: - paidByMemberId

    @Test("paidByMemberId: decodes valid UUID")
    func paidByValid() {
        let p = Self.payload(["paid_by_member_id": .string(Self.memberA.uuidString)])
        #expect(p.ledgerPaidByMemberId == Self.memberA)
    }

    @Test("paidByMemberId: nil when missing")
    func paidByMissing() {
        #expect(Self.payload([:]).ledgerPaidByMemberId == nil)
    }

    @Test("paidByMemberId: nil when malformed")
    func paidByMalformed() {
        let p = Self.payload(["paid_by_member_id": .string("not-a-uuid")])
        #expect(p.ledgerPaidByMemberId == nil)
    }

    // MARK: - isInKind

    @Test("isInKind: true when bool true")
    func inKindTrue() {
        #expect(Self.payload(["in_kind": .bool(true)]).ledgerIsInKind == true)
    }

    @Test("isInKind: false when bool false")
    func inKindFalse() {
        #expect(Self.payload(["in_kind": .bool(false)]).ledgerIsInKind == false)
    }

    @Test("isInKind: false when missing")
    func inKindMissing() {
        #expect(Self.payload([:]).ledgerIsInKind == false)
    }

    // MARK: - participants

    @Test("participants: decodes uuid array")
    func participantsList() {
        let p = Self.payload([
            "participants": .array([
                .string(Self.memberA.uuidString),
                .string(Self.memberB.uuidString),
            ])
        ])
        #expect(p.ledgerParticipants == [Self.memberA, Self.memberB])
    }

    @Test("participants: empty when missing")
    func participantsMissing() {
        #expect(Self.payload([:]).ledgerParticipants.isEmpty)
    }

    @Test("participants: skips malformed entries silently")
    func participantsMalformedSkipped() {
        let p = Self.payload([
            "participants": .array([
                .string(Self.memberA.uuidString),
                .string("garbage"),
                .string(Self.memberB.uuidString),
            ])
        ])
        #expect(p.ledgerParticipants == [Self.memberA, Self.memberB])
    }

    // MARK: - splitMode

    @Test("splitMode: decodes each canonical case", arguments: SplitMode.allCases)
    func splitModeAll(mode: SplitMode) {
        let p = Self.payload(["split_mode": .string(mode.rawValue)])
        #expect(p.ledgerSplitMode == mode)
    }

    @Test("splitMode: nil when missing")
    func splitModeMissing() {
        #expect(Self.payload([:]).ledgerSplitMode == nil)
    }

    @Test("splitMode: nil for unknown raw value")
    func splitModeUnknown() {
        let p = Self.payload(["split_mode": .string("custom_mode")])
        #expect(p.ledgerSplitMode == nil)
    }

    // MARK: - splitBreakdown

    @Test("splitBreakdown: decodes canonical mig 00370 shape")
    func splitBreakdownDecodes() {
        let p = Self.payload([
            "split_breakdown": .array([
                .object([
                    "member_id":   .string(Self.memberA.uuidString),
                    "share_cents": .int(5000),
                ]),
                .object([
                    "member_id":   .string(Self.memberB.uuidString),
                    "share_cents": .int(5000),
                ]),
            ])
        ])
        let rows = p.ledgerSplitBreakdown
        #expect(rows.count == 2)
        #expect(rows[0].memberId == Self.memberA && rows[0].shareCents == 5000)
        #expect(rows[1].memberId == Self.memberB && rows[1].shareCents == 5000)
    }

    @Test("splitBreakdown: empty when missing")
    func splitBreakdownMissing() {
        #expect(Self.payload([:]).ledgerSplitBreakdown.isEmpty)
    }

    @Test("splitBreakdown: skips malformed rows silently")
    func splitBreakdownMalformedSkipped() {
        let p = Self.payload([
            "split_breakdown": .array([
                .object([
                    "member_id":   .string(Self.memberA.uuidString),
                    "share_cents": .int(5000),
                ]),
                .object([
                    "member_id":   .string("bad"),
                    "share_cents": .int(5000),
                ]),
                .object(["share_cents": .int(5000)]),  // missing member_id
            ])
        ])
        let rows = p.ledgerSplitBreakdown
        #expect(rows.count == 1)
        #expect(rows[0].memberId == Self.memberA)
    }

    // MARK: - participantCount + isShared (fallback rules)

    @Test("participantCount: prefers split_breakdown when >= 2")
    func participantCountPrefersBreakdown() {
        let p = Self.payload([
            "split_breakdown": .array([
                .object(["member_id": .string(Self.memberA.uuidString),
                         "share_cents": .int(4000)]),
                .object(["member_id": .string(Self.memberB.uuidString),
                         "share_cents": .int(3000)]),
                .object(["member_id": .string(Self.memberC.uuidString),
                         "share_cents": .int(3000)]),
            ]),
            "participants": .array([.string(Self.memberA.uuidString)]),  // only 1, ignored
        ])
        #expect(p.ledgerParticipantCount == 3)
        #expect(p.ledgerIsShared == true)
    }

    @Test("participantCount: falls back to participants when no breakdown")
    func participantCountFallsBackToParticipants() {
        let p = Self.payload([
            "participants": .array([
                .string(Self.memberA.uuidString),
                .string(Self.memberB.uuidString),
            ])
        ])
        #expect(p.ledgerParticipantCount == 2)
        #expect(p.ledgerIsShared == true)
    }

    @Test("participantCount: nil when both empty or singular")
    func participantCountNil() {
        // Empty payload
        #expect(Self.payload([:]).ledgerParticipantCount == nil)
        #expect(Self.payload([:]).ledgerIsShared == false)

        // Single participant — not "shared"
        let single = Self.payload([
            "participants": .array([.string(Self.memberA.uuidString)])
        ])
        #expect(single.ledgerParticipantCount == nil)
        #expect(single.ledgerIsShared == false)

        // Single breakdown row — not "shared"
        let oneRow = Self.payload([
            "split_breakdown": .array([
                .object(["member_id": .string(Self.memberA.uuidString),
                         "share_cents": .int(10_000)]),
            ])
        ])
        #expect(oneRow.ledgerParticipantCount == nil)
        #expect(oneRow.ledgerIsShared == false)
    }

    // MARK: - clientId + sourceResourceId

    @Test("clientId: returns stamped string")
    func clientIdPresent() {
        let cid = UUID().uuidString
        let p = Self.payload(["client_id": .string(cid)])
        #expect(p.ledgerClientId == cid)
    }

    @Test("sourceResourceId: decodes valid UUID")
    func sourceResourceIdValid() {
        let p = Self.payload([
            "source_resource_id": .string(Self.resourceX.uuidString)
        ])
        #expect(p.ledgerSourceResourceId == Self.resourceX)
    }

    @Test("sourceResourceId: nil when malformed")
    func sourceResourceIdMalformed() {
        let p = Self.payload(["source_resource_id": .string("nope")])
        #expect(p.ledgerSourceResourceId == nil)
    }

    // MARK: - LedgerEntry proxy

    @Test("LedgerEntry proxies metadata helpers")
    func ledgerEntryProxy() {
        let e = Self.entry(metadata: Self.payload([
            "note":              .string("Bocadillos"),
            "paid_by_member_id": .string(Self.memberA.uuidString),
            "in_kind":           .bool(true),
            "split_mode":        .string("equal"),
            "participants": .array([
                .string(Self.memberA.uuidString),
                .string(Self.memberB.uuidString),
            ]),
        ]))
        #expect(e.note == "Bocadillos")
        #expect(e.paidByMemberId == Self.memberA)
        #expect(e.isInKind == true)
        #expect(e.splitMode == .equal)
        #expect(e.participants == [Self.memberA, Self.memberB])
        #expect(e.participantCount == 2)
        #expect(e.isShared == true)
    }

    @Test("LedgerEntry with empty metadata exposes all-nil/empty defaults")
    func ledgerEntryEmpty() {
        let e = Self.entry(metadata: .object([:]))
        #expect(e.note == nil)
        #expect(e.paidByMemberId == nil)
        #expect(e.isInKind == false)
        #expect(e.splitMode == nil)
        #expect(e.participants.isEmpty)
        #expect(e.splitBreakdown.isEmpty)
        #expect(e.participantCount == nil)
        #expect(e.isShared == false)
        #expect(e.clientId == nil)
        #expect(e.sourceResourceId == nil)
    }
}
