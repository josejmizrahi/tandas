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

    @ViewBuilder
    private func tallySection(detail: GroupDecisionDetail) -> some View {
        Section(L10n.Decisions.tallySection) {
            if detail.tally.voteCount == 0 {
                Text(L10n.Decisions.tallyNoVotes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                tallyRow(label: VoteValue.yes.label, image: VoteValue.yes.systemImageName, count: detail.tally.yesCount, tint: .green)
                tallyRow(label: VoteValue.no.label, image: VoteValue.no.systemImageName, count: detail.tally.noCount, tint: .red)
                if detail.tally.abstainCount > 0 {
                    tallyRow(label: VoteValue.abstain.label, image: VoteValue.abstain.systemImageName, count: detail.tally.abstainCount, tint: .gray)
                }
                if detail.tally.blockCount > 0 {
                    tallyRow(label: VoteValue.block.label, image: VoteValue.block.systemImageName, count: detail.tally.blockCount, tint: .orange)
                }
            }
        }
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
