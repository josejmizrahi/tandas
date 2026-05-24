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
    @State private var breakdown: [ResourceMemberContribution] = []
    @State private var isLoading: Bool = true
    @State private var presentedSheet: SharedMoneySheet?
    @State private var refreshTick: Int = 0

    enum SharedMoneySheet: Identifiable {
        case record, contribute
        var id: String {
            switch self {
            case .record:     return "record"
            case .contribute: return "contribute"
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

            HStack(spacing: RuulSpacing.sm) {
                RuulButton("Aportar", style: .secondary, size: .medium) {
                    presentedSheet = .contribute
                }
                RuulButton("Registrar gasto", style: .secondary, size: .medium) {
                    presentedSheet = .record
                }
            }

            footer

            breakdownView
        }
        .padding(RuulSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ruulCardSurface(.solid)
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .task(id: refreshTick) { await load() }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
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
            VStack(alignment: .leading, spacing: 2) {
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

    /// Phase 4.5 brick B: per-member breakdown rendered below the
    /// summary footer. Sorted by `contributedCents` descending — the
    /// largest backer leads. Hidden when fewer than 2 members have
    /// contributed (one-person breakdown is redundant with the global
    /// "Aportado" total). The current user's row is labeled "Tú" to
    /// echo the `SharedMoneyCard` convention.
    @ViewBuilder
    private var breakdownView: some View {
        let sorted = sortedBreakdown
        if sorted.count >= 2 {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Quién aportó")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.top, RuulSpacing.xs)
                ForEach(sorted) { row in
                    breakdownRow(row, total: totalContributed)
                }
            }
        }
    }

    @ViewBuilder
    private func breakdownRow(
        _ row: ResourceMemberContribution,
        total: Int64
    ) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Text(memberLabel(for: row.memberId))
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: RuulSpacing.xs)
            Text(formatted(row.contributedCents))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.primary)
            Text(percentLabel(row.contributedCents, total: total))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
                .frame(minWidth: 36, alignment: .trailing)
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

    private var sortedBreakdown: [ResourceMemberContribution] {
        breakdown.sorted { $0.contributedCents > $1.contributedCents }
    }

    private var totalContributed: Int64 {
        breakdown.map(\.contributedCents).reduce(0, +)
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

    private func percentLabel(_ value: Int64, total: Int64) -> String {
        guard total > 0 else { return "—" }
        let pct = Int(round(Double(value) * 100.0 / Double(total)))
        return "\(pct)%"
    }

    // MARK: - Side effects

    @MainActor
    private func load() async {
        // Load summary + per-member breakdown in parallel. Both
        // soft-fail to the empty state — the slot is ambient context,
        // not a hard dependency of the host. Capture Sendable values
        // (UUID, String) up front so Swift 6 strict concurrency
        // doesn't flag MoneyContext (non-Sendable closures inside).
        let resourceId = context.resourceId
        let currency = context.currency
        let repo = app.fundRepo
        async let summaryTask: ResourceMoneySummary? = {
            try? await repo.summaryForResource(
                resourceId,
                preferredCurrency: currency
            )
        }()
        async let breakdownTask: [ResourceMemberContribution] = {
            (try? await repo.breakdownForResource(
                resourceId,
                preferredCurrency: currency
            )) ?? []
        }()
        summary = await summaryTask
        breakdown = await breakdownTask
        isLoading = false
    }

    private func handleDidChange() {
        // Trigger reload of this slot AND signal the host so it can
        // refresh its own activity feed / related counters.
        refreshTick &+= 1
        context.onDidChange()
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
