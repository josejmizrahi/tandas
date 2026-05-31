import SwiftUI
import RuulCore

/// Full list surface for Primitiva 16 (Decisions / Voting). Apple Mail
/// style: filter chip between Abiertas / Cerradas, toolbar add =
/// propose, row tap pushes the universal detail view.
public struct DecisionsListView: View {
    @Bindable var store: DecisionsStore
    let groupId: UUID
    /// V2-G2 sub-slice 2 — routing for the reference row inside
    /// `DecisionDetailView`. Optional so previews and surfaces that
    /// don't need cross-primitive navigation can pass nil.
    let onSelectReference: ((DeepLink) -> Void)?
    /// V2-G2 sub-slice 3+4+5 — stores the ProposeDecisionSheet picker
    /// uses when the chosen decision type binds to a specific entity
    /// (sanction_appeal / mandate_revoke / mandate_grant / membership
    /// / rule_change).
    let sanctionsStore: SanctionsStore?
    let mandatesStore: MandatesStore?
    let membersStore: MembersStore?
    let rulesStore: RulesStore?
    /// V2-G2 sub-slice 8 — when present, the propose sheet inherits the
    /// group's `default_method` + `default_legitimacy_source` instead of
    /// hardcoded majority/majority.
    let decisionRulesStore: DecisionRulesStore?

    @State private var filter: DecisionFilter = .open

    public init(
        store: DecisionsStore,
        groupId: UUID,
        onSelectReference: ((DeepLink) -> Void)? = nil,
        sanctionsStore: SanctionsStore? = nil,
        mandatesStore: MandatesStore? = nil,
        membersStore: MembersStore? = nil,
        rulesStore: RulesStore? = nil,
        decisionRulesStore: DecisionRulesStore? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.onSelectReference = onSelectReference
        self.sanctionsStore = sanctionsStore
        self.mandatesStore = mandatesStore
        self.membersStore = membersStore
        self.rulesStore = rulesStore
        self.decisionRulesStore = decisionRulesStore
    }

    public var body: some View {
        List {
            filterSection
            content
        }
        .navigationTitle(L10n.Decisions.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginProposing(defaults: decisionRulesStore?.rules)
                } label: {
                    Label(L10n.Decisions.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isProposePresented) {
            ProposeDecisionSheet(
                store: store,
                groupId: groupId,
                sanctionsStore: sanctionsStore,
                mandatesStore: mandatesStore,
                membersStore: membersStore,
                rulesStore: rulesStore
            )
        }
        .sheet(isPresented: $store.isVotePresented) {
            VoteSheet(store: store, groupId: groupId)
        }
        .navigationDestination(for: GroupDecisionSummary.self) { summary in
            DecisionDetailView(
                store: store,
                groupId: groupId,
                decisionId: summary.id,
                initial: summary,
                onSelectReference: onSelectReference
            )
        }
        .task {
            async let decisions: Void = store.refreshIfNeeded(groupId: groupId)
            async let rules: Void = decisionRulesStore?.refreshIfNeeded(groupId: groupId) ?? ()
            _ = await (decisions, rules)
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        Section {
            Picker("", selection: $filter) {
                Text(L10n.Decisions.filterOpen).tag(DecisionFilter.open)
                Text(L10n.Decisions.filterHistory).tag(DecisionFilter.history)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.Decisions.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.Decisions.retry)) {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            switch filter {
            case .open:    openSection
            case .history: historySection
            }
        }
    }

    @ViewBuilder
    private var openSection: some View {
        if store.open.isEmpty {
            ContentUnavailableView {
                Label(L10n.Decisions.emptyTitle, systemImage: "checkmark.seal")
            } description: {
                Text(L10n.Decisions.emptyDescription)
            } actions: {
                Button {
                    store.beginProposing(defaults: decisionRulesStore?.rules)
                } label: {
                    Text(L10n.Decisions.addButton)
                }
                .buttonStyle(.glassProminent)
            }
            .listRowBackground(Color.clear)
        } else {
            Section(L10n.Decisions.sectionOpen) {
                ForEach(store.open) { decision in
                    NavigationLink(value: decision) {
                        DecisionRow(decision: decision)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if store.history.isEmpty {
            ContentUnavailableView(
                String(localized: L10n.Decisions.emptyTitle),
                systemImage: "clock.arrow.circlepath"
            )
            .listRowBackground(Color.clear)
        } else {
            Section(L10n.Decisions.sectionHistory) {
                ForEach(store.history) { decision in
                    NavigationLink(value: decision) {
                        DecisionRow(decision: decision)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Placeholder decisión")
                .font(.body.weight(.semibold))
            Text("Placeholder método")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }

    private enum DecisionFilter: Hashable {
        case open, history
    }
}

private struct DecisionRow: View {
    let decision: GroupDecisionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(decision.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                statusBadge
            }
            HStack(spacing: 10) {
                Label(decision.method.label, systemImage: decision.method.systemImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if decision.tally.voteCount > 0 {
                    Text("\(decision.tally.voteCount) votos")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if let myVote = decision.myVoteValue {
                Label(myVote.label, systemImage: myVote.systemImageName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let tint: Color = {
            switch decision.status {
            case .open:      return .blue
            case .passed:    return .green
            case .rejected:  return .red
            case .cancelled: return .gray
            case .draft:     return .secondary
            case .executed:  return .green
            case .closed:    return .green
            }
        }()
        Text(decision.status.label)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}
