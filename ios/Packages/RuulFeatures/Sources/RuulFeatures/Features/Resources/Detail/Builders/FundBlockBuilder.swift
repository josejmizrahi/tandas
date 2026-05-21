import Foundation
import RuulCore

/// Builder for Fund resources. Produces the universal `ResourceBlocks`
/// tree from a `ResourceRow` (fund rows live in `public.resources` with
/// `resource_type = 'fund'`).
///
/// Balance is read from `ResourceRow.metadata["balance_cents"]` when
/// present (populated by `LedgerRepository` aggregate or `funds.balance_cents`
/// from mig 00139). Falls back to "—" when missing.
///
/// Source per Addendum F: `ResourceRow` from `LiveResourceRepository`.
public struct FundBlockBuilder: BlockBuilder {
    public typealias Source = ResourceRow

    public init() {}

    // MARK: - BlockBuilder

    public func build(
        source: ResourceRow,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks {
        let isLocked = source.metadata["locked"]?.boolValue == true
        let name = source.metadata["name"]?.stringValue ?? "Fondo"

        let currency   = source.metadata["currency"]?.stringValue ?? "MXN"
        let balanceCts = source.metadata["balance_cents"]?.intValue
        let hasBalance = balanceCts != nil
        let formatted  = balanceCts.map { formatCents($0, currency: currency) } ?? "—"

        // Subtitle: family only when active. "Bloqueado" is load-bearing
        // state worth surfacing here; the active default ("Fondo · Activo")
        // would otherwise echo with the hero/properties.
        let identity = IdentityRibbon(
            icon: "banknote",
            tint: .funds,
            title: name,
            subtitleSegments: isLocked ? ["Fondo", "Bloqueado"] : ["Fondo"]
        )

        let state: StateHeadline = {
            if isLocked {
                return StateHeadline(
                    headline: "Bloqueado",
                    supportingFacts: [formatted],
                    primaryAction: nil,
                    urgency: .terminal
                )
            }
            // Pre-fix the hero was "Saldo —" when balance was unknown,
            // which reads as broken. Split the two cases: when the
            // balance is known, the hero IS the amount (the Money block
            // below carries the "Saldo" label + ledger link). When
            // unknown, the hero is a calm prompt; the Money block's
            // em-dash + "Ver libro" already handles the empty state.
            let headline = hasBalance ? formatted : "Aún sin movimientos"
            return StateHeadline(
                headline: headline,
                supportingFacts: [],
                primaryAction: PrimaryAction(
                    label: "Registrar movimiento",
                    symbol: "plus.circle",
                    style: .standard,
                    kind: .openContribute          // routes to AddLedgerEntry sheet
                ),
                urgency: .ambient
            )
        }()

        let balanceBlock = CapabilityBlock(
            id: "balance",
            title: "Saldo",
            icon: "banknote",
            layoutKind: .balance,
            payload: CapabilityBlock.Payload(
                balance: CapabilityBlock.BalanceFields(
                    primary: formatted,
                    supporting: nil,    // Phase E: last-entry line from LedgerRepository
                    delta: nil
                )
            ),
            footerVerb: "Ver libro",
            openDestinationId: "fund.ledger"
        )

        return ResourceBlocks(
            identity: identity,
            state: StateHeadlineResolver.normalize(state, fallback: name),
            properties: PropertiesBlock(rows: []),
            capabilities: [balanceBlock],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }

    // MARK: - Helpers

    private func formatCents(_ cents: Int, currency: String) -> String {
        let amount = Decimal(cents) / 100
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "\(currency) \(cents / 100)"
    }
}
