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
    /// V2-G2 sub-slice 2 — caller-provided routing for the reference
    /// row. When nil, the row still renders but isn't tappable.
    let onSelectReference: ((DeepLink) -> Void)?

    public init(
        store: DecisionsStore,
        groupId: UUID,
        decisionId: UUID,
        initial: GroupDecisionSummary,
        onSelectReference: ((DeepLink) -> Void)? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.decisionId = decisionId
        self.initial = initial
        self.onSelectReference = onSelectReference
    }

    public var body: some View {
        List {
            heroSection
            if let detail = store.detail, detail.id == decisionId {
                bodySection(detail: detail)
                methodNarrativeSection(detail: detail)
                referenceSection(detail: detail)
                if !detail.options.isEmpty {
                    optionsSection(detail: detail)
                }
                tallySection(detail: detail)
                myVoteSection(detail: detail)
                if detail.status != .open {
                    resultSection(detail: detail)
                    outcomeAppliedSection(detail: detail)
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

    /// V2-G2 sub-slice 2 — show what entity the decision affects when
    /// `reference_kind` + `reference_id` are populated. Tappable when
    /// the caller wired `onSelectReference` and the reference maps to a
    /// known `DeepLink` case.
    @ViewBuilder
    private func referenceSection(detail: GroupDecisionDetail) -> some View {
        if let kind = detail.referenceKind {
            Section(L10n.Decisions.referenceSection) {
                referenceRow(kind: kind, referenceId: detail.referenceId)
            }
        }
    }

    @ViewBuilder
    private func referenceRow(kind: String, referenceId: UUID?) -> some View {
        let label = referenceLabel(for: kind)
        let icon = referenceIcon(for: kind)
        let link = referenceDeepLink(kind: kind, referenceId: referenceId)

        if let link, let onSelectReference {
            Button {
                onSelectReference(link)
            } label: {
                referenceRowContent(label: label, icon: icon, showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            referenceRowContent(label: label, icon: icon, showsChevron: false)
        }
    }

    @ViewBuilder
    private func referenceRowContent(
        label: LocalizedStringResource,
        icon: String,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(label)
                .font(.body)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func referenceLabel(for kind: String) -> LocalizedStringResource {
        switch kind {
        case "sanction":       return L10n.Decisions.referenceSanction
        case "dispute":        return L10n.Decisions.referenceDispute
        case "mandate":        return L10n.Decisions.referenceMandate
        case "mandate_grant":  return L10n.Decisions.referenceMandateGrant
        case "mandate_revoke": return L10n.Decisions.referenceMandateRevoke
        case "dissolution":    return L10n.Decisions.referenceDissolution
        case "rule":           return L10n.Decisions.referenceRule
        case "membership":     return L10n.Decisions.referenceMembership
        default:               return L10n.Decisions.referenceOther
        }
    }

    private func referenceIcon(for kind: String) -> String {
        switch kind {
        case "sanction":       return "exclamationmark.shield"
        case "dispute":        return "scale.3d"
        case "mandate",
             "mandate_grant",
             "mandate_revoke": return "person.crop.rectangle.badge.checkmark"
        case "dissolution":    return "archivebox"
        case "rule":           return "list.bullet.rectangle"
        case "membership":     return "person.crop.circle"
        default:               return "link"
        }
    }

    /// Maps the decision's reference tuple to a DeepLink. Returns nil
    /// for kinds without a destination yet (e.g., dissolution / rule
    /// don't have entity deep links in the V3-A4 shape).
    private func referenceDeepLink(kind: String, referenceId: UUID?) -> DeepLink? {
        guard let referenceId else { return nil }
        switch kind {
        case "sanction":
            return .sanction(groupId: groupId, sanctionId: referenceId)
        case "dispute":
            return .dispute(groupId: groupId, disputeId: referenceId)
        case "mandate", "mandate_grant", "mandate_revoke":
            return .mandate(groupId: groupId, mandateId: referenceId)
        default:
            return nil
        }
    }

    /// V2-G2 sub-slice 2 — surface the side effect the backend already
    /// applied when this decision finalized with outcome=passed. The
    /// dispatch table mirrors finalize_vote's reference_kind branch:
    /// sanction→reversed, dispute→resolved, mandate_revoke→revoked,
    /// dissolution→approved. mandate_grant attaches source_decision_id
    /// (the mandate doesn't get created by the decision itself in the
    /// current backend; the row should already exist with the decision
    /// id stamped).
    @ViewBuilder
    private func outcomeAppliedSection(detail: GroupDecisionDetail) -> some View {
        if let outcome = detail.result?.outcome, outcome == "passed",
           let kind = detail.referenceKind,
           let copy = outcomeHint(for: kind) {
            Section(L10n.Decisions.outcomeAppliedSection) {
                Label {
                    Text(copy)
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func outcomeHint(for kind: String) -> LocalizedStringResource? {
        switch kind {
        case "sanction":       return L10n.Decisions.outcomeSanctionReversed
        case "dispute":        return L10n.Decisions.outcomeDisputeResolved
        case "mandate_revoke": return L10n.Decisions.outcomeMandateRevoked
        case "mandate_grant",
             "mandate":        return L10n.Decisions.outcomeMandateConfirmed
        case "dissolution":    return L10n.Decisions.outcomeDissolutionApproved
        case "membership":     return L10n.Decisions.outcomeMembershipApplied
        case "rule":           return L10n.Decisions.outcomeRuleApplied
        default:               return nil
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
