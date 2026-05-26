//
//  ResourceMoneySlot.swift
//  ResourceKit
//
//  SharedMoney Phase 4 (brick B): the universal Money Block on any
//  resource detail page. Renders when `ResourceConfig.moneyContext`
//  is non-nil. Polymorphic across resource types — the slot only
//  needs `(groupId, resourceId, currency, members)`; the data layer
//  (`fundRepo.summaryForResource`) reads `resource_money_view`
//  (mig 00362) and aggregates the per-resource totals.
//
//  Two CTAs drive the group-scoped Phase 2/3 sheets pre-filled with
//  `sourceResource = (id, name)`:
//    - "Aportar"          → ContributeToSharedMoneySheet
//    - "Registrar gasto"  → RecordSharedExpenseSheet
//
//  Per `doctrine_in_kind_contributions.md`, the "Aportar" path also
//  covers capital contributions (land, construction-from-pocket, etc.)
//  — contributions are tagged with the resource via source_resource_id
//  so the resource's "contributed_cents" tracks running capital. See
//  the canonical warehouse use case in that doctrine.
//

import SwiftUI
import RuulCore
import RuulUI

struct ResourceMoneySlot: View {
    let context: MoneyContext

    @Environment(AppState.self) private var app

    @State private var summary: ResourceMoneySummary?
    /// FASE 4 Wave 3 (2026-05-25): polymorphic per-member breakdown
    /// derived client-side from the resource's ledger entries so the
    /// row can surface BOTH the `contributor` role (capital injection)
    /// AND the `paid_by` role (out-of-pocket payer for expenses). The
    /// server `breakdownForResource` view only carries contributions —
    /// reading entries directly gives both, plus keeps the projection
    /// authoritative (we don't drift from the ledger).
    @State private var entries: [LedgerEntry] = []
    @State private var isLoading: Bool = true
    @State private var presentedSheet: SharedMoneySheet?
    @State private var refreshTick: Int = 0

    /// Combined participation roles aggregated from `entries`. A member
    /// shows up if they appear as `from_member` on a contribution OR
    /// as `metadata.paid_by_member_id` on an expense. Both, when applicable.
    fileprivate struct MemberRoleAggregate: Identifiable {
        let memberId: UUID
        let contributedCents: Int64
        let paidByCents: Int64
        var id: UUID { memberId }
        var totalCents: Int64 { contributedCents + paidByCents }
    }

    enum SharedMoneySheet: Identifiable {
        case picker, record, contribute, settle
        var id: String {
            switch self {
            case .picker:     return "picker"
            case .record:     return "record"
            case .contribute: return "contribute"
            case .settle:     return "settle"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            Text("Dinero del recurso")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)

            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                if isLoading && summary == nil {
                    placeholderHeadline
                } else {
                    headline
                }
            }

            Button {
                presentedSheet = .picker
            } label: {
                Text("Registrar movimiento")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .tint(.primary)

            footer

            breakdownView
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.solid)
        .task(id: refreshTick) { await load() }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .picker:
                RegisterMovementSheet(onPick: routePickedKind)
            case .record:
                RecordSharedExpenseSheet(
                    groupId: context.groupId,
                    currency: context.currency,
                    members: context.members,
                    sourceResource: (id: context.resourceId, name: context.resourceName),
                    onDidRecord: handleDidChange
                )
                .presentationDetents([.medium, .large])
            case .contribute:
                ContributeToSharedMoneySheet(
                    groupId: context.groupId,
                    currency: context.currency,
                    sourceResource: (id: context.resourceId, name: context.resourceName),
                    onDidContribute: handleDidChange
                )
                .presentationDetents([.medium, .large])
            case .settle:
                // Phase 5: peer-to-peer settlement. Suggested
                // recipient = the largest contributor (most likely
                // the person others owe). Caller can override.
                SettlementSheet(
                    groupId: context.groupId,
                    resourceId: context.resourceId,
                    currency: context.currency,
                    members: context.members,
                    suggestedToMemberId: topContributorMemberId,
                    onDidSettle: handleDidChange
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var placeholderHeadline: some View {
        RuulMoneyView(amount: 0, currency: context.currency, size: .large, color: .neutral)
            .redacted(reason: .placeholder)
        Text("Saldo del recurso")
            .font(.caption)
            .foregroundStyle(Color.secondary)
    }

    @ViewBuilder
    private var headline: some View {
        // Net displayed = contributed - spent.
        // - For a capital project (warehouse): contributed > 0 → positive net.
        // - For an event with people fronting cash: spent > 0 → negative net
        //   ("the group owes its members N for this event").
        RuulMoneyView(
            amount: netAmount,
            currency: context.currency,
            size: .large,
            color: tone
        )
        Text(headlineCaption)
            .font(.caption)
            .foregroundStyle(Color.secondary)
    }

    @ViewBuilder
    private var footer: some View {
        if let s = summary, s.hasActivity {
            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                if s.contributedCents > 0 {
                    Text("Aportado: \(formatted(s.contributedCents))")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if s.spentCents > 0 {
                    Text("Gastado: \(formatted(s.spentCents))")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if let last = s.lastActivityAt {
                    Text("Última actividad: \(last.ruulRelative)")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        } else {
            Text("Aún no hay movimientos asociados a este recurso.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    /// FASE 4 Wave 3 (2026-05-25): polymorphic role breakdown. A member
    /// row shows up to two roles inline — `aportó $X` (contribution) and
    /// `pagó $Y de su bolsa` (paid_by on expenses). Sorted by total
    /// involvement descending so the largest backer leads. Hidden when
    /// no member crossed the threshold (no contributions AND no paid_by).
    @ViewBuilder
    private var breakdownView: some View {
        let roles = memberRoleAggregates
        // Hide when there's nothing distinct to show vs the global
        // "Aportado/Gastado" footer (single member with only contribution
        // == redundant with the summary).
        let shouldShow = roles.count >= 2
            || roles.contains(where: { $0.paidByCents > 0 })
        if shouldShow {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Quién puso dinero")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.top, RuulSpacing.xs)
                ForEach(roles) { row in
                    breakdownRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func breakdownRow(_ row: MemberRoleAggregate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.sm) {
            Text(memberLabel(for: row.memberId))
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: RuulSpacing.xs)
            VStack(alignment: .trailing, spacing: 1) {
                if row.contributedCents > 0 {
                    Text("Aportó \(formatted(row.contributedCents))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.primary)
                }
                if row.paidByCents > 0 {
                    Text("Pagó \(formatted(row.paidByCents)) de su bolsa")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    // MARK: - Derived state

    private var netAmount: Decimal {
        let cents = summary?.netCents ?? 0
        return Decimal(cents) / 100
    }

    private var tone: RuulMoneyView.SemanticColor {
        guard let s = summary else { return .neutral }
        if s.netCents > 0 { return .positive }
        if s.netCents < 0 { return .negative }
        return .neutral
    }

    private var headlineCaption: String {
        guard let s = summary, s.hasActivity else {
            return "Saldo del recurso"
        }
        if s.netCents > 0 {
            return "Aportes netos"
        }
        if s.netCents < 0 {
            return "El grupo debe por este recurso"
        }
        return "Movimientos balanceados"
    }

    /// Polymorphic per-member aggregate. Contributions are summed from
    /// `entry.fromMemberId` on `contribution` rows; paid-by is summed
    /// from `entry.paidByMemberId` on `expense` rows (mig 00366 tri-role
    /// payload). Members with zero in both columns are dropped. Sort
    /// key = total involvement so the largest backer leads.
    private var memberRoleAggregates: [MemberRoleAggregate] {
        var dict: [UUID: (contributed: Int64, paidBy: Int64)] = [:]
        for e in entries {
            switch e.type {
            case LedgerEntry.Kind.contribution:
                if let from = e.fromMemberId {
                    dict[from, default: (0, 0)].contributed += e.amountCents
                }
            case LedgerEntry.Kind.expense:
                if let payer = e.paidByMemberId {
                    dict[payer, default: (0, 0)].paidBy += e.amountCents
                }
            default:
                break
            }
        }
        return dict
            .map { id, v in
                MemberRoleAggregate(
                    memberId: id,
                    contributedCents: v.contributed,
                    paidByCents: v.paidBy
                )
            }
            .filter { $0.totalCents > 0 }
            .sorted { $0.totalCents > $1.totalCents }
    }

    /// Suggested settlement recipient — the top contributor remains the
    /// most likely creditor in the pool. Falls back to nil so the
    /// SettlementSheet just won't pre-fill `to`.
    private var topContributorMemberId: UUID? {
        memberRoleAggregates
            .sorted { $0.contributedCents > $1.contributedCents }
            .first?.memberId
    }

    /// Maps a `group_members.id` to its display name from
    /// `context.members`. When the row belongs to the current viewer,
    /// renders as "Tú" — same convention used in SharedMoneyCard /
    /// RecordSharedExpenseSheet so the user recognizes themselves
    /// at a glance.
    private func memberLabel(for memberId: UUID) -> String {
        let viewerMemberId = context.members
            .first(where: { $0.member.userId == app.session?.user.id })?
            .member.id
        if memberId == viewerMemberId { return "Tú" }
        return context.members
            .first(where: { $0.member.id == memberId })?
            .displayName ?? "Miembro"
    }

    // MARK: - Side effects

    @MainActor
    private func load() async {
        // Load summary + per-resource entries in parallel. Both
        // soft-fail to the empty state — the slot is ambient context,
        // not a hard dependency of the host. Capture Sendable values
        // (UUID, String) up front so Swift 6 strict concurrency
        // doesn't flag MoneyContext (non-Sendable closures inside).
        let resourceId = context.resourceId
        let currency = context.currency
        let fundRepo = app.fundRepo
        let ledgerRepo = app.ledgerRepo
        async let summaryTask: ResourceMoneySummary? = {
            try? await fundRepo.summaryForResource(
                resourceId,
                preferredCurrency: currency
            )
        }()
        async let entriesTask: [LedgerEntry] = {
            (try? await ledgerRepo.listForResource(
                resourceId,
                limit: 500
            )) ?? []
        }()
        summary = await summaryTask
        entries = await entriesTask
        isLoading = false
    }

    private func handleDidChange() {
        // Trigger reload of this slot AND signal the host so it can
        // refresh its own activity feed / related counters.
        refreshTick &+= 1
        context.onDidChange()
    }

    private func routePickedKind(_ kind: RegisterMovementSheet.Kind) {
        switch kind {
        case .contribution:  presentedSheet = .contribute
        case .expense:       presentedSheet = .record
        case .settlement:    presentedSheet = .settle
        case .reimbursement, .payout, .poolCharge:
            // Resource-level slot no rutea reimbursement/payout/poolCharge —
            // los tres viven como acciones del Money Detail del grupo
            // (ahí hay member picker contextual). Colapsamos a
            // `record` (el caso similar más cercano).
            presentedSheet = .record
        }
    }

    // MARK: - Formatting

    private func formatted(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = context.currency
        f.maximumFractionDigits = 0
        return f.string(from: amount as NSDecimalNumber) ?? "\(context.currency) \(cents / 100)"
    }
}
