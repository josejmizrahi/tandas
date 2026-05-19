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
        let formatted  = balanceCts.map { formatCents($0, currency: currency) } ?? "—"

        let identity = IdentityRibbon(
            icon: "banknote",
            tint: .funds,
            title: name,
            subtitleSegments: ["Fondo", isLocked ? "Bloqueado" : source.status.capitalized]
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
            return StateHeadline(
                headline: "Saldo \(formatted)",
                supportingFacts: [],
                primaryAction: PrimaryAction(
                    label: "Aportar",
                    symbol: "plus.circle",
                    style: .standard,
                    kind: .openContribute          // routes to FundRepository.contribute
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
