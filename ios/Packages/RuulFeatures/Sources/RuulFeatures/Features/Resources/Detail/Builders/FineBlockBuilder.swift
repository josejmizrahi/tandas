import Foundation
import RuulCore

/// Builder for Fine records. Adapts the `Fine` model (decoded from
/// `public.fines_view`, mig 00149) to the universal block tree so
/// `UniversalResourceDetailView` can render fines without knowing their
/// type.
///
/// Source per Addendum F: `Fine` from `FineRepository`.
/// Mutations dispatched from `onPrimaryAction`:
///   - `.payFine`  → `FineRepository.payFine` → `rpc('pay_fine')`
///   - `.castVote` (appeal) → `VoteRepository.startAppeal`
public struct FineBlockBuilder: BlockBuilder {
    public typealias Source = Fine

    public init() {}

    // MARK: - BlockBuilder

    public func build(
        source: Fine,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks {
        let isDebtor = viewer.userId == source.userId
        let isPaid   = source.paid || source.status == .paid
        let isVoided = source.waived || source.status == .voided
        let inAppeal = source.status == .inAppeal

        let identity = IdentityRibbon(
            icon: "exclamationmark.triangle",
            tint: .fines,
            title: source.reason,
            subtitleSegments: ["Multa", source.status.displayLabel]
        )

        let state: StateHeadline = {
            if isPaid {
                return StateHeadline(
                    headline: "Pagada",
                    supportingFacts: [source.amountFormatted],
                    primaryAction: nil,
                    urgency: .terminal
                )
            }
            if isVoided {
                return StateHeadline(
                    headline: "Anulada",
                    supportingFacts: [source.amountFormatted],
                    primaryAction: nil,
                    urgency: .terminal
                )
            }
            if inAppeal {
                return StateHeadline(
                    headline: "En apelación",
                    supportingFacts: [source.amountFormatted, source.reason],
                    primaryAction: nil,
                    urgency: .actionable
                )
            }
            if isDebtor {
                return StateHeadline(
                    headline: "\(source.amountFormatted) por pagar",
                    supportingFacts: [source.reason],
                    primaryAction: PrimaryAction(
                        label: "Pagar multa",
                        symbol: "creditcard",
                        style: .standard,
                        kind: .payFine              // → FineRepository.payFine → rpc('pay_fine')
                    ),
                    urgency: .urgent
                )
            }
            // Observer (not the debtor)
            return StateHeadline(
                headline: "\(source.amountFormatted) sin pagar",
                supportingFacts: [source.reason],
                primaryAction: nil,
                urgency: .ambient
            )
        }()

        let amountBlock = CapabilityBlock(
            id: "amount",
            title: "Monto",
            icon: "banknote",
            layoutKind: .balance,
            payload: CapabilityBlock.Payload(
                balance: CapabilityBlock.BalanceFields(
                    primary: source.amountFormatted,
                    supporting: source.reason,
                    delta: nil
                )
            ),
            openDestinationId: nil
        )

        // Appeal timeline block when the fine is in appeal
        var capabilities: [CapabilityBlock] = [amountBlock]
        if inAppeal {
            let appealBlock = CapabilityBlock(
                id: "appeal",
                title: "Apelación",
                icon: "person.badge.clock",
                layoutKind: .timelineMini,
                payload: CapabilityBlock.Payload(
                    timeline: [
                        CapabilityBlock.TimelineEntry(
                            id: "appeal_open",
                            sentence: "Apelación abierta",
                            relativeTime: source.updatedAt.relativeTimeString
                        )
                    ]
                ),
                footerVerb: "Ver votación",
                openDestinationId: "appeal.vote"
            )
            capabilities.append(appealBlock)
        }

        return ResourceBlocks(
            identity: identity,
            state: StateHeadlineResolver.normalize(state, fallback: source.reason),
            properties: makeProperties(source: source, now: now),
            capabilities: capabilities,
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }

    // MARK: - Properties

    private func makeProperties(source: Fine, now: Date) -> PropertiesBlock {
        var rows: [FactRow] = [
            FactRow(id: "amount", key: "Monto", value: source.amountFormatted),
            FactRow(id: "status", key: "Estado", value: source.status.displayLabel)
        ]
        if let paidAt = source.paidAt {
            rows.append(FactRow(id: "paid_at", key: "Pagada", value: shortDate(paidAt)))
        }
        if let waivedAt = source.waivedAt {
            rows.append(FactRow(id: "waived_at", key: "Anulada", value: shortDate(waivedAt)))
        }
        return PropertiesBlock(rows: rows)
    }

    // MARK: - Helpers

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}

// MARK: - Date helper (internal to this builder)

private extension Date {
    var relativeTimeString: String {
        let delta = Date.now.timeIntervalSince(self)
        if delta < 3600 { return "hace \(Int(delta / 60)) min" }
        if delta < 86400 { return "hace \(Int(delta / 3600))h" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "d MMM"
        return f.string(from: self)
    }
}
