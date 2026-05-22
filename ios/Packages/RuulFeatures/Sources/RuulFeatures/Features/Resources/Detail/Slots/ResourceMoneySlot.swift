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

    // MARK: - Side effects

    @MainActor
    private func load() async {
        do {
            summary = try await app.fundRepo.summaryForResource(
                context.resourceId,
                preferredCurrency: context.currency
            )
        } catch {
            // Fall back silently to the empty state — the slot is
            // ambient context, not a hard dependency of the host.
            summary = nil
        }
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
