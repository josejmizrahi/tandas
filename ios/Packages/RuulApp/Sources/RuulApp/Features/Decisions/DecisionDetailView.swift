import SwiftUI
import RuulCore

/// Universal detail surface for one decision. Apple Mail thread feel:
/// hero (title + body + status) on top, then options (tally per
/// option), then "Mi voto" inline, then a result section when closed.
public struct DecisionDetailView: View {
    @Bindable var store: DecisionsStore
    let groupId: UUID
    let decisionId: UUID
    /// Last-known list row for the same decision. Used as a fallback
    /// while the full detail is loading so the screen never flashes
    /// "Not found".
    let initial: GroupDecisionSummary

    public init(
        store: DecisionsStore,
        groupId: UUID,
        decisionId: UUID,
        initial: GroupDecisionSummary
    ) {
        self.store = store
        self.groupId = groupId
        self.decisionId = decisionId
        self.initial = initial
    }

    public var body: some View {
        List {
            heroSection
            if let detail = store.detail, detail.id == decisionId {
                bodySection(detail: detail)
                methodNarrativeSection(detail: detail)
                if !detail.options.isEmpty {
                    optionsSection(detail: detail)
                }
                tallySection(detail: detail)
                myVoteSection(detail: detail)
                if detail.status != .open {
                    resultSection(detail: detail)
                }
                actionsSection(detail: detail)
            } else {
                loadingPlaceholder
            }
        }
        .navigationTitle(initial.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: decisionId) {
            await store.loadDetail(decisionId: decisionId)
        }
        .refreshable {
            await store.refreshDetail()
        }
        .sheet(isPresented: $store.isVotePresented) {
            VoteSheet(store: store, groupId: groupId)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(initial.title)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    statusBadge(for: store.detail?.status ?? initial.status)
                }
                HStack(spacing: 12) {
                    Label(initial.method.label, systemImage: initial.method.systemImageName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let when = (store.detail?.closesAt ?? initial.closesAt) {
                        Label(
                            "\(String(localized: L10n.Decisions.closesAtLabel)) \(when.formatted(.dateTime.day().month().hour().minute()))",
                            systemImage: "clock"
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    } else if (store.detail?.status ?? initial.status) == .open {
                        Text(L10n.Decisions.openEnded)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let name = initial.createdByDisplayName, !name.isEmpty {
                    Text("\(String(localized: L10n.Decisions.proposedBy)) \(name)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func bodySection(detail: GroupDecisionDetail) -> some View {
        Section(L10n.Decisions.bodySection) {
            if let body = detail.body, !body.isEmpty {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 2)
            } else {
                Text(L10n.Decisions.bodyEmpty)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func optionsSection(detail: GroupDecisionDetail) -> some View {
        Section(L10n.Decisions.optionsSection) {
            ForEach(detail.options) { option in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.body.weight(.medium))
                        if let body = option.body, !body.isEmpty {
                            Text(body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    let count = detail.optionTally[option.id] ?? 0
                    Text("\(count)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if detail.myVote?.optionId == option.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
    }

    /// V2-G1 sub-slice 3 — top-of-detail narrative card explaining
    /// "cómo se decide esto" in human terms before any tally numbers.
    /// Threshold and quorum hints surface here too, when set, so the
    /// reader sees them before opening the result section.
    @ViewBuilder
    private func methodNarrativeSection(detail: GroupDecisionDetail) -> some View {
        Section(L10n.Decisions.methodNarrativeSection) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: detail.method.systemImageName)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.method.label)
                        .font(.body.weight(.semibold))
                    Text(narrativeHint(for: detail.method))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            if let threshold = detail.thresholdPct {
                LabeledContent {
                    Text(percent(threshold))
                        .monospacedDigit()
                } label: {
                    Text(L10n.Decisions.tallyThresholdLabel)
                }
            }
            if let quorum = detail.quorumPct {
                LabeledContent {
                    Text(percent(quorum))
                        .monospacedDigit()
                } label: {
                    Text(L10n.Decisions.tallyQuorumLabel)
                }
            }
        }
    }

    @ViewBuilder
    private func tallySection(detail: GroupDecisionDetail) -> some View {
        Section(L10n.Decisions.tallySection) {
            if detail.method == .admin {
                Text(L10n.Decisions.tallyAdminNoBallots)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if detail.tally.voteCount == 0 {
                Text(L10n.Decisions.tallyNoVotes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                methodTallyRows(detail: detail)

                LabeledContent {
                    Text("\(detail.tally.voteCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } label: {
                    Text(L10n.Decisions.tallyVotesCounted)
                }

                if shouldHighlightBlock(method: detail.method),
                   detail.tally.blockCount > 0 {
                    Text(detail.method == .veto
                         ? L10n.Decisions.tallyVetoHighlight
                         : L10n.Decisions.tallyBlockHighlight)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// V2-G1 sub-slice 3 — per-method tally rows. We render only the
    /// buckets that are semantically meaningful for the method, with
    /// the canonical labels (`A favor / Objeto / Me retiro` for
    /// consensus; `Consiento / Bloqueo` for consent; etc.). Other
    /// methods fall back to the broad yes/no/abstain/block shape that
    /// pre-V2-G1 surfaced.
    @ViewBuilder
    private func methodTallyRows(detail: GroupDecisionDetail) -> some View {
        let tally = detail.tally
        let method = detail.method
        switch method {
        case .consensus:
            tallyRow(label: VoteValue.yes.label(for: method),
                     image: VoteValue.yes.systemImageName,
                     count: tally.yesCount, tint: .green)
            tallyRow(label: VoteValue.no.label(for: method),
                     image: VoteValue.no.systemImageName,
                     count: tally.noCount, tint: .red)
            if tally.abstainCount > 0 {
                tallyRow(label: VoteValue.abstain.label(for: method),
                         image: VoteValue.abstain.systemImageName,
                         count: tally.abstainCount, tint: .gray)
            }
        case .consent:
            tallyRow(label: VoteValue.yes.label(for: method),
                     image: VoteValue.yes.systemImageName,
                     count: tally.yesCount, tint: .green)
            tallyRow(label: VoteValue.block.label(for: method),
                     image: VoteValue.block.systemImageName,
                     count: tally.blockCount, tint: .orange)
        case .veto:
            tallyRow(label: VoteValue.yes.label(for: method),
                     image: VoteValue.yes.systemImageName,
                     count: tally.yesCount, tint: .green)
            tallyRow(label: VoteValue.block.label(for: method),
                     image: VoteValue.block.systemImageName,
                     count: tally.blockCount, tint: .orange)
        case .admin:
            // Render nothing — caller short-circuited with the admin
            // notice above.
            EmptyView()
        case .majority, .supermajority,
             .rankedChoice, .weighted, .other:
            tallyRow(label: VoteValue.yes.label,
                     image: VoteValue.yes.systemImageName,
                     count: tally.yesCount, tint: .green)
            tallyRow(label: VoteValue.no.label,
                     image: VoteValue.no.systemImageName,
                     count: tally.noCount, tint: .red)
            if tally.abstainCount > 0 {
                tallyRow(label: VoteValue.abstain.label,
                         image: VoteValue.abstain.systemImageName,
                         count: tally.abstainCount, tint: .gray)
            }
            if tally.blockCount > 0 {
                tallyRow(label: VoteValue.block.label,
                         image: VoteValue.block.systemImageName,
                         count: tally.blockCount, tint: .orange)
            }
        }
    }

    private func narrativeHint(for method: DecisionMethod) -> LocalizedStringResource {
        switch method {
        case .admin:         return L10n.Decisions.tallyAdminNoBallots
        case .majority:      return L10n.Decisions.tallyMajorityHint
        case .supermajority: return L10n.Decisions.tallySupermajorityHint
        case .consensus:     return L10n.Decisions.tallyConsensusHint
        case .consent:       return L10n.Decisions.tallyConsentHint
        case .veto:          return L10n.Decisions.tallyVetoHint
        case .rankedChoice:  return L10n.Decisions.tallyRankedHint
        case .weighted:      return L10n.Decisions.tallyWeightedHint
        case .other:         return L10n.Decisions.methodOtherSubtitle
        }
    }

    private func shouldHighlightBlock(method: DecisionMethod) -> Bool {
        method == .consent || method == .veto
    }

    private func percent(_ value: Decimal) -> String {
        // The backend stores 0…100 — render 1 decimal place when
        // non-integer, otherwise plain.
        let asDouble = NSDecimalNumber(decimal: value).doubleValue
        if asDouble.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(asDouble))%"
        }
        return String(format: "%.1f%%", asDouble)
    }

    @ViewBuilder
    private func tallyRow(
        label: LocalizedStringResource,
        image: String,
        count: Decimal,
        tint: Color
    ) -> some View {
        HStack {
            Label(label, systemImage: image)
                .foregroundStyle(tint)
            Spacer()
            Text("\(NSDecimalNumber(decimal: count).stringValue)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func myVoteSection(detail: GroupDecisionDetail) -> some View {
        Section(L10n.Decisions.myVoteLabel) {
            if let myVote = detail.myVote, let value = myVote.voteValue {
                HStack {
                    Label(value.label, systemImage: value.systemImageName)
                        .font(.body.weight(.medium))
                    Spacer()
                    if let castAt = myVote.castAt {
                        Text(castAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let reason = myVote.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if detail.isOpenForVoting {
                    Button {
                        store.beginVoting(on: detail)
                    } label: {
                        Label(L10n.Decisions.changeVoteButton, systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.glass)
                }
            } else if detail.isOpenForVoting {
                Text(L10n.Decisions.myVoteNone)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    store.beginVoting(on: detail)
                } label: {
                    Label(L10n.Decisions.voteButton, systemImage: "checkmark.seal")
                }
                .buttonStyle(.glassProminent)
            } else {
                Text(L10n.Decisions.myVoteNone)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultSection(detail: GroupDecisionDetail) -> some View {
        Section(L10n.Decisions.resultSection) {
            if let result = detail.result {
                if let outcome = result.outcome {
                    HStack {
                        Text(outcomeLabel(for: outcome))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(outcomeColor(for: outcome))
                        Spacer()
                        if let when = detail.decidedAt {
                            Text(when.formatted(.dateTime.day().month().year()))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if let reason = result.cancelReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(detail.status.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionsSection(detail: GroupDecisionDetail) -> some View {
        if detail.isOpenForVoting {
            Section {
                Button {
                    Task { _ = await store.finalize(decisionId: detail.id, groupId: groupId) }
                } label: {
                    Label(L10n.Decisions.finalizeButton, systemImage: "checkmark.seal")
                }
                Button(role: .destructive) {
                    Task { _ = await store.cancel(decisionId: detail.id, reason: nil, groupId: groupId) }
                } label: {
                    Label(L10n.Decisions.cancelDecisionButton, systemImage: "xmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        Section {
            HStack {
                ProgressView()
                Text("Cargando…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: DecisionStatus) -> some View {
        let tint: Color = {
            switch status {
            case .open:      return .blue
            case .passed:    return .green
            case .rejected:  return .red
            case .cancelled: return .gray
            case .draft:     return .secondary
            }
        }()
        Text(status.label)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func outcomeLabel(for outcome: String) -> LocalizedStringResource {
        switch outcome {
        case "passed":    return L10n.Decisions.outcomePassed
        case "rejected":  return L10n.Decisions.outcomeRejected
        case "no_quorum": return L10n.Decisions.outcomeNoQuorum
        case "cancelled": return L10n.Decisions.outcomeCancelled
        default:          return DecisionStatus(rawValue: outcome)?.label ?? L10n.Decisions.statusOpen
        }
    }

    private func outcomeColor(for outcome: String) -> Color {
        switch outcome {
        case "passed":    return .green
        case "rejected":  return .red
        case "no_quorum": return .orange
        case "cancelled": return .gray
        default:          return .primary
        }
    }
}
