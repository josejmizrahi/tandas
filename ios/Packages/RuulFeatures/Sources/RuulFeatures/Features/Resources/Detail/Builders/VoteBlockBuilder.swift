import Foundation
import RuulCore

/// Builder for Vote records. Adapts the `Vote` model (decoded from
/// `public.votes`) to the universal block tree so
/// `UniversalResourceDetailView` can render votes without knowing their type.
///
/// Source per Addendum F: `Vote` from `VoteRepository`.
/// `viewerHasVoted` is passed via init — the host fetches it from
/// `vote_casts` keyed on `viewer.userId`. Builder remains pure.
///
/// Mutations dispatched from `onPrimaryAction`:
///   - `.castVote` → `VoteRepository.castVote` → `rpc('cast_vote')`
public struct VoteBlockBuilder: BlockBuilder {
    public typealias Source = Vote

    /// True when the viewer has already cast a ballot for this vote.
    /// Passed by the host so the builder stays async-free.
    public let viewerHasVoted: Bool

    public init(viewerHasVoted: Bool = false) {
        self.viewerHasVoted = viewerHasVoted
    }

    // MARK: - BlockBuilder

    public func build(
        source: Vote,
        viewer: BlockViewerContext,
        now: Date
    ) -> ResourceBlocks {
        let isOpen = source.status == .open
        let isClosed = source.status == .closed
            || source.status == .resolved
            || source.status == .quorumFailed
            || source.status == .cancelled

        let totalEligible = source.counts?.totalEligible ?? 0
        let totalCast     = (source.counts?.inFavor ?? 0)
                          + (source.counts?.against ?? 0)
                          + (source.counts?.abstained ?? 0)

        let identity = IdentityRibbon(
            icon: "checkmark.circle",
            tint: .votes,
            title: source.title,
            subtitleSegments: ["Votación", source.voteType.displayName]
        )

        let state: StateHeadline = {
            if isClosed || source.status == .resolved {
                let resolution = source.counts?.resolution.map { $0.displayName } ?? ""
                return StateHeadline(
                    headline: "Cerrada · \(resolution)".trimmingCharacters(in: CharacterSet(charactersIn: " ·")),
                    supportingFacts: ["\(totalCast) de \(totalEligible) votos emitidos"],
                    primaryAction: nil,
                    urgency: .terminal
                )
            }
            if source.status == .quorumFailed {
                return StateHeadline(
                    headline: "Quórum no alcanzado",
                    supportingFacts: ["\(totalCast) de \(totalEligible)"],
                    primaryAction: nil,
                    urgency: .terminal
                )
            }
            if isOpen && !viewerHasVoted {
                return StateHeadline(
                    headline: "Falta tu voto",
                    supportingFacts: ["\(totalCast) de \(totalEligible) emitidos"],
                    primaryAction: PrimaryAction(
                        label: "Emitir voto",
                        symbol: "checkmark.circle",
                        style: .standard,
                        kind: .castVote              // → VoteRepository.castVote → rpc('cast_vote')
                    ),
                    urgency: .actionable
                )
            }
            // Open + viewer voted
            return StateHeadline(
                headline: "Esperando más votos",
                supportingFacts: ["\(totalCast) de \(totalEligible)"],
                primaryAction: nil,
                urgency: .ambient
            )
        }()

        let tallyBlock = CapabilityBlock(
            id: "tally",
            title: "Conteo",
            icon: "chart.bar",
            layoutKind: .progress,
            payload: CapabilityBlock.Payload(
                progress: CapabilityBlock.ProgressFields(
                    current: totalCast,
                    total: totalEligible,
                    label: "\(totalCast) de \(totalEligible) votos"
                )
            ),
            footerVerb: "Ver detalle",
            openDestinationId: "vote.detail",
            isViewerObligation: isOpen && !viewerHasVoted
        )

        return ResourceBlocks(
            identity: identity,
            state: StateHeadlineResolver.normalize(state, fallback: source.title),
            properties: makeProperties(source: source, now: now),
            capabilities: [tallyBlock],
            relations: [],
            activityHead: [],
            hasMoreActivity: false
        )
    }

    // MARK: - Properties

    private func makeProperties(source: Vote, now: Date) -> PropertiesBlock {
        var rows: [FactRow] = [
            FactRow(id: "type", key: "Tipo", value: source.voteType.displayName),
            FactRow(id: "closes_at", key: "Cierra", value: shortDate(source.closesAt))
        ]
        if let desc = source.description, !desc.isEmpty {
            rows.append(FactRow(id: "description", key: "Descripción", value: desc))
        }
        return PropertiesBlock(rows: rows)
    }

    // MARK: - Helpers

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Display name helpers

private extension VoteType {
    var displayName: String {
        switch self {
        case .fineAppeal:      return "Apelación"
        case .ruleChange:      return "Cambio de regla"
        case .ruleRepeal:      return "Derogación"
        case .memberRemoval:   return "Expulsión"
        case .fundWithdrawal:  return "Retiro de fondo"
        case .roleAssignment:  return "Asignación de rol"
        case .generalProposal: return "Propuesta general"
        case .slotDispute:     return "Disputa de turno"
        case .ledgerReview:    return "Revisión de movimiento"
        }
    }
}

private extension VoteResolution {
    var displayName: String {
        switch self {
        case .passed:      return "Aprobada"
        case .failed:      return "Rechazada"
        case .quorumFailed: return "Sin quórum"
        }
    }
}
