import Foundation

/// Typed accessors over the ledger payload shape (jsonb). Both
/// `LedgerEntry.metadata` (the live row) and `SystemEvent.payload` of
/// `.ledgerEntryCreated` (the atom copy stamped by trigger mig 00371)
/// share this shape, so the helpers live on `JSONConfig` and both
/// surfaces consume the same code path.
///
/// Keys decoded:
/// - `note`                — free-form user note
/// - `paid_by_member_id`   — tri-role payer (mig 00366)
/// - `in_kind`             — non-cash contribution flag (mig 00364)
/// - `participants`        — uuid[] of members owing a share (mig 00367)
/// - `split_mode`          — Splitwise mode tag (mig 00370)
/// - `split_breakdown`     — canonical per-member share array (mig 00370)
/// - `client_id`           — idempotency key (mig 00351)
/// - `source_resource_id`  — attribution to event/asset/space (mig 00360)
public extension JSONConfig {
    var ledgerNote: String? {
        guard case let .string(s) = self["note"] ?? .null, !s.isEmpty else {
            return nil
        }
        return s
    }

    var ledgerPaidByMemberId: UUID? {
        self["paid_by_member_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// Settlement recipient (or expense reimbursement target). Stamped
    /// into the atom payload by the trigger from mig 20260524180000.
    /// FASE 4 PR-1: used by `HistoryItemPresentation` to render the
    /// bi-role "X le pagó $Y a Z" settlement title.
    var ledgerToMemberId: UUID? {
        self["to_member_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// Settlement payer. Stamped into the atom payload by the same trigger.
    var ledgerFromMemberId: UUID? {
        self["from_member_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    var ledgerIsInKind: Bool {
        self["in_kind"]?.boolValue == true
    }

    var ledgerParticipants: [UUID] {
        guard case let .array(rows) = self["participants"] ?? .null else {
            return []
        }
        return rows.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
    }

    var ledgerSplitMode: SplitMode? {
        self["split_mode"]?.stringValue.flatMap(SplitMode.init(rawValue:))
    }

    var ledgerSplitBreakdown: [SplitBreakdown] {
        guard case let .array(rows) = self["split_breakdown"] ?? .null else {
            return []
        }
        return rows.compactMap { row -> SplitBreakdown? in
            guard
                let memberStr = row["member_id"]?.stringValue,
                let memberId = UUID(uuidString: memberStr),
                let shares = row["share_cents"]?.intValue
            else { return nil }
            return SplitBreakdown(memberId: memberId, shareCents: Int64(shares))
        }
    }

    /// Number of distinct people the entry is divided among. Prefers
    /// `split_breakdown.count` and falls back to `participants` for
    /// entries written before mig 00370. Nil when not a split/shared
    /// movement.
    var ledgerParticipantCount: Int? {
        let breakdown = ledgerSplitBreakdown.count
        if breakdown >= 2 { return breakdown }
        let parts = ledgerParticipants.count
        if parts >= 2 { return parts }
        return nil
    }

    var ledgerIsShared: Bool { ledgerParticipantCount != nil }

    var ledgerClientId: String? {
        self["client_id"]?.stringValue
    }

    var ledgerSourceResourceId: UUID? {
        self["source_resource_id"]?.stringValue
            .flatMap(UUID.init(uuidString:))
    }
}

public extension LedgerEntry {
    var note: String?               { metadata.ledgerNote }
    var paidByMemberId: UUID?       { metadata.ledgerPaidByMemberId }
    var isInKind: Bool              { metadata.ledgerIsInKind }
    var participants: [UUID]        { metadata.ledgerParticipants }
    var splitMode: SplitMode?       { metadata.ledgerSplitMode }
    var splitBreakdown: [SplitBreakdown] { metadata.ledgerSplitBreakdown }
    var participantCount: Int?      { metadata.ledgerParticipantCount }
    var isShared: Bool              { metadata.ledgerIsShared }
    var clientId: String?           { metadata.ledgerClientId }
    var sourceResourceId: UUID?     { metadata.ledgerSourceResourceId }
}
