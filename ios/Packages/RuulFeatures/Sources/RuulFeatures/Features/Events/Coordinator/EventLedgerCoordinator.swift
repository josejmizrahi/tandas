import Foundation
import Observation
import OSLog
import RuulCore

// File name kept for git continuity; the type is the polymorphic
// `ResourceLedgerCoordinator` that drives the Money surface for ANY
// Resource — events, assets, funds. Founder framing 2026-05-10:
// Money is a capability section on ResourceDetail, not an event-only
// feature.

/// Coordinator backing the per-resource Money surface. Loads ledger
/// entries scoped to a single resource (`resource_id = context.resourceId`
/// per Taxonomy §29), exposes a per-member balance projection computed
/// client-side, and drives the AddLedgerEntrySheet form.
///
/// Append-only: there is no edit / delete path here intentionally. The
/// rule engine + admin tooling handles corrections via compensating
/// entries in Phase 4+.
@Observable @MainActor
public final class ResourceLedgerCoordinator {
    public enum EntryKind: String, CaseIterable, Identifiable, Hashable {
        case expense        // Yo pagué algo por el grupo
        case contribution   // Yo aporté al evento (pot, fund-shaped)
        case settlement     // Yo le pagué a alguien (cierre de IOU)
        case payout         // El grupo le paga a un miembro (pot → miembro)

        public var id: String { rawValue }

        public var displayLabel: String {
            switch self {
            case .expense:      return "Gasto"
            case .contribution: return "Aportación"
            case .settlement:   return "Pago a un miembro"
            case .payout:       return "Pago del grupo"
            }
        }

        public var iconName: String {
            switch self {
            case .expense:      return "cart.fill"
            case .contribution: return "arrow.up.bin.fill"
            case .settlement:   return "arrow.left.arrow.right"
            case .payout:       return "tray.and.arrow.down.fill"
            }
        }

        public var summaryHint: String {
            switch self {
            case .expense:      return "Yo pagué algo por el grupo. El sistema lo cuenta a mi favor."
            case .contribution: return "Yo aporté dinero al evento. Suma a un pot común."
            case .settlement:   return "Yo le pagué directo a otro miembro (cierre de cuenta)."
            case .payout:       return "El grupo (pot común) le paga a un miembro — ej. reembolso al host."
            }
        }

        /// Ledger entry type string written to `public.ledger_entries.type`.
        /// Canonical Taxonomy §2.E values.
        public var ledgerType: String {
            switch self {
            case .expense:      return LedgerEntry.Kind.expense
            case .contribution: return LedgerEntry.Kind.contribution
            case .settlement:   return LedgerEntry.Kind.settlement
            case .payout:       return LedgerEntry.Kind.payout
            }
        }

        /// True when this kind requires the user to pick a `to_member` (the
        /// counter-party that received the money). Settlement + payout both
        /// need a recipient — expense + contribution treat the group as the
        /// implicit recipient.
        public var requiresCounterparty: Bool {
            self == .settlement || self == .payout
        }

        /// True when the `from_member_id` column is recorded as the current
        /// user. False for payouts where the implicit "from" side is the
        /// group's collective pot (no specific member).
        public var requiresFromMember: Bool {
            self != .payout
        }
    }

    public let context: ResourceLedgerContext
    public var groupId: UUID    { context.groupId }
    public var resourceId: UUID { context.resourceId }
    public var displayName: String { context.displayName }

    public private(set) var entries: [LedgerEntry] = []
    public private(set) var members: [MemberWithProfile] = []
    public private(set) var isLoading: Bool = true
    public private(set) var isSubmitting: Bool = false
    public private(set) var error: String?
    public var addSheetPresented: Bool = false

    // Form state — flat fields the sheet binds to.
    public var formKind: EntryKind = .expense
    public var formAmountText: String = ""
    public var formNote: String = ""
    /// `group_members.id` (not user id) of the counter-party. Only used for
    /// `.settlement`. The payer (`from_member`) is always the current user.
    public var formCounterpartyMemberId: UUID?

    private var currentUserId: UUID { context.currentUserId }
    private let ledgerRepo: any LedgerRepository
    private let groupsRepo: any GroupsRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.ledger")

    public init(
        context: ResourceLedgerContext,
        ledgerRepo: any LedgerRepository,
        groupsRepo: any GroupsRepository
    ) {
        self.context = context
        self.ledgerRepo = ledgerRepo
        self.groupsRepo = groupsRepo
    }

    // MARK: - Loading

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let entriesTask = ledgerRepo.listForResource(resourceId, limit: 200)
            async let membersTask = groupsRepo.membersWithProfiles(of: groupId)
            entries = try await entriesTask
            members = try await membersTask.sorted { lhs, rhs in
                if lhs.member.isFounder != rhs.member.isFounder {
                    return lhs.member.isFounder
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        } catch {
            log.warning("load failed: \(error.localizedDescription)")
            self.error = "No pudimos cargar los movimientos."
        }
    }

    // MARK: - Derived state

    /// Current user's `group_members.id`, or nil if not a member. Used as the
    /// `from_member_id` on every entry the user records.
    public var currentMemberId: UUID? {
        members.first(where: { $0.member.userId == currentUserId })?.member.id
    }

    /// Counter-party options for the active form kind. For settlement we
    /// exclude the current user (you can't settle with yourself). For payout
    /// every member is eligible — the host of a dinner getting reimbursed
    /// from the pot is the canonical case.
    public var counterpartyOptions: [MemberWithProfile] {
        if formKind == .payout { return members }
        return members.filter { $0.member.userId != currentUserId }
    }

    /// Parsed amount in cents. Returns nil for empty/negative/unparseable.
    /// Accepts "200", "200.50", "200,50" — Decimal-tolerant of locale.
    public var parsedAmountCents: Int64? {
        let trimmed = formAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = [trimmed,
                          trimmed.replacingOccurrences(of: ",", with: "."),
                          trimmed.replacingOccurrences(of: ".", with: ",")]
        for c in candidates {
            if let d = Decimal(string: c), d >= 0 {
                let multiplied = d * 100
                let rounded = NSDecimalNumber(decimal: multiplied).int64Value
                return rounded
            }
        }
        return nil
    }

    public var canSubmit: Bool {
        guard !isSubmitting else { return false }
        guard parsedAmountCents != nil else { return false }
        // Payouts don't need a `from_member` (the pot is the implicit source),
        // but every other kind does — we record the current user as `from`.
        if formKind.requiresFromMember && currentMemberId == nil { return false }
        if formKind.requiresCounterparty && formCounterpartyMemberId == nil {
            return false
        }
        return true
    }

    /// Per-member running balance from `entries`. Positive = the group
    /// owes them; negative = they owe the group. Only includes members who
    /// have at least one entry.
    public struct MemberBalance: Identifiable, Hashable {
        public let memberId: UUID
        public let displayName: String
        public let avatarURL: URL?
        public let netCents: Int64
        public var id: UUID { memberId }
    }

    public var memberBalances: [MemberBalance] {
        var net: [UUID: Int64] = [:]
        for entry in entries {
            // Expense + contribution: payer's balance goes up (group owes them).
            // Settlement: payer down, recipient up (debt closes the other way).
            // Payout: pot pays a member — that member's "group owes them"
            // tally goes DOWN since they just received what they were owed.
            switch entry.type {
            case LedgerEntry.Kind.expense, LedgerEntry.Kind.contribution:
                if let from = entry.fromMemberId {
                    net[from, default: 0] += entry.amountCents
                }
            case LedgerEntry.Kind.settlement, LedgerEntry.Kind.reimbursement:
                if let from = entry.fromMemberId {
                    net[from, default: 0] += entry.amountCents
                }
                if let to = entry.toMemberId {
                    net[to, default: 0] -= entry.amountCents
                }
            case LedgerEntry.Kind.payout:
                if let to = entry.toMemberId {
                    net[to, default: 0] -= entry.amountCents
                }
            default:
                // Other types (fine_issued, fine_paid) — skip in this
                // event-scoped projection. Phase 4 will fold them in.
                break
            }
        }
        return net.compactMap { (memberId, cents) -> MemberBalance? in
            guard let mwp = members.first(where: { $0.member.id == memberId }) else {
                return nil
            }
            return MemberBalance(
                memberId: memberId,
                displayName: mwp.displayName,
                avatarURL: mwp.avatarURL,
                netCents: cents
            )
        }.sorted { abs($0.netCents) > abs($1.netCents) }
    }

    public var totalSpentCents: Int64 {
        entries.reduce(into: Int64(0)) { acc, entry in
            if entry.type == LedgerEntry.Kind.expense
                || entry.type == LedgerEntry.Kind.contribution {
                acc += entry.amountCents
            }
        }
    }

    // MARK: - Submit

    public func resetForm() {
        formKind = .expense
        formAmountText = ""
        formNote = ""
        formCounterpartyMemberId = nil
        error = nil
    }

    @discardableResult
    public func submit() async -> LedgerEntry? {
        guard canSubmit, let amountCents = parsedAmountCents else { return nil }
        // Payouts: `from_member_id` stays nil (the pot is the implicit
        // source). Everything else records the current user as `from`.
        let fromMember: UUID? = formKind.requiresFromMember ? currentMemberId : nil
        if formKind.requiresFromMember, fromMember == nil { return nil }
        let toMember: UUID? = formKind.requiresCounterparty ? formCounterpartyMemberId : nil
        let trimmedNote = formNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata: JSONConfig = trimmedNote.isEmpty
            ? .object([:])
            : .object(["note": .string(trimmedNote)])

        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        do {
            let entry = try await ledgerRepo.recordEntry(
                groupId: groupId,
                resourceId: resourceId,
                type: formKind.ledgerType,
                amountCents: amountCents,
                fromMemberId: fromMember,
                toMemberId: toMember,
                currency: "MXN",
                metadata: metadata
            )
            // Insert at the front so the UI updates without a refetch.
            entries.insert(entry, at: 0)
            resetForm()
            return entry
        } catch {
            self.error = humanize(error: error)
            log.warning("submit failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("auth required") { return "Tu sesión expiró. Volvé a entrar." }
        if raw.contains("not a member") { return "No eres miembro activo de este grupo." }
        if raw.contains("amount") { return "El monto debe ser mayor a cero." }
        if raw.contains("invalid ledger entry type") { return "Tipo de movimiento no soportado." }
        if raw.contains("resource does not belong") { return "Este movimiento no pertenece a este evento." }
        return "No pudimos registrar el movimiento. Intenta de nuevo."
    }

    // MARK: - Display helpers

    public func displayName(for memberId: UUID?) -> String? {
        guard let id = memberId else { return nil }
        return members.first(where: { $0.member.id == id })?.displayName
    }

    public func avatarURL(for memberId: UUID?) -> URL? {
        guard let id = memberId else { return nil }
        return members.first(where: { $0.member.id == id })?.avatarURL
    }
}
