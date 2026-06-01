import SwiftUI
import RuulCore

/// Full list of contributions (Primitiva 9) for a group. Grouped by
/// `contribution_type` in canonical display order. Toolbar add =
/// log self-claim. Swipe leading/trailing = verify/reject (backend
/// gates by `contribution.verify` + self-check, so the UI shows the
/// actions for any claimed row that I didn't author and surfaces a
/// `UserFacingError` if my role doesn't have the permission).
public struct ContributionsListView: View {
    @Bindable var store: ContributionsStore
    let groupId: UUID
    let myMembershipId: UUID?
    /// Optional filters threaded into the read RPC. nil = group-wide.
    let filterMembershipId: UUID?
    let filterResourceId: UUID?

    @State private var alertMessage: String?

    public init(
        store: ContributionsStore,
        groupId: UUID,
        myMembershipId: UUID? = nil,
        filterMembershipId: UUID? = nil,
        filterResourceId: UUID? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.myMembershipId = myMembershipId
        self.filterMembershipId = filterMembershipId
        self.filterResourceId = filterResourceId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Contributions.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId, membershipId: filterMembershipId, resourceId: filterResourceId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginLogging()
                } label: {
                    Label(L10n.Contributions.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isLogPresented) {
            LogContributionSheet(store: store, groupId: groupId)
        }
        .alert(
            "No se pudo verificar",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            ),
            presenting: alertMessage
        ) { _ in
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: { message in
            Text(message)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId, membershipId: filterMembershipId, resourceId: filterResourceId)
        }
    }

    /// Verify-row eligibility: only `claimed` rows that I didn't
    /// author. Other statuses are terminal; the backend will reject
    /// self-verify but UX-wise the swipe shouldn't appear.
    private func canVerify(_ contribution: GroupContribution) -> Bool {
        guard contribution.status == .claimed else { return false }
        if let myMembershipId, contribution.membershipId == myMembershipId {
            return false
        }
        return true
    }

    private func performVerify(_ contribution: GroupContribution, outcome: ContributionVerifyOutcome) {
        Task {
            let ok = await store.verify(
                contributionId: contribution.id,
                outcome: outcome,
                groupId: groupId,
                membershipId: filterMembershipId,
                resourceId: filterResourceId
            )
            if !ok {
                alertMessage = store.errorMessage
                store.clearError()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.Contributions.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.Contributions.retry)) {
                    Task {
                        await store.refresh(
                            groupId: groupId,
                            membershipId: filterMembershipId,
                            resourceId: filterResourceId
                        )
                    }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if !store.hasContributions {
                ContentUnavailableView {
                    Label(L10n.Contributions.emptyTitle, systemImage: "hands.sparkles")
                } description: {
                    Text(L10n.Contributions.emptyDescription)
                } actions: {
                    Button {
                        store.beginLogging()
                    } label: {
                        Text(L10n.Contributions.addButton)
                    }
                    .buttonStyle(.glassProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                loadedSections
            }
        }
    }

    @ViewBuilder
    private var loadedSections: some View {
        ForEach(ContributionType.displayOrder, id: \.self) { type in
            if let bucket = store.contributionsByType[type], !bucket.isEmpty {
                Section {
                    ForEach(bucket) { contribution in
                        row(for: contribution)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if canVerify(contribution) {
                                    Button {
                                        performVerify(contribution, outcome: .verified)
                                    } label: {
                                        Label(
                                            String(localized: L10n.Contributions.verifyAction),
                                            systemImage: "checkmark.seal"
                                        )
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canVerify(contribution) {
                                    Button(role: .destructive) {
                                        performVerify(contribution, outcome: .rejected)
                                    } label: {
                                        Label(
                                            String(localized: L10n.Contributions.rejectAction),
                                            systemImage: "xmark.circle"
                                        )
                                    }
                                }
                            }
                    }
                } header: {
                    Label(type.label, systemImage: type.systemImageName)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for contribution: GroupContribution) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(contribution.headline)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                statusBadge(for: contribution.status)
            }
            if let title = contribution.title, !title.isEmpty,
               let desc = contribution.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if let amount = contribution.amount, let unit = contribution.unit {
                    Text("\(amount.formatted()) \(unit)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                }
                if let who = contribution.memberDisplayName, !who.isEmpty {
                    Text("Registró \(who)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let when = contribution.when {
                    Text(when, format: .dateTime.day().month().year())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(for status: ContributionStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon(status)).font(.caption2.weight(.semibold))
            Text(status.label).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
        .foregroundStyle(.secondary)
    }

    private func statusIcon(_ status: ContributionStatus) -> String {
        switch status {
        case .claimed:  return "hourglass"
        case .verified: return "checkmark.seal.fill"
        case .rejected: return "xmark.circle.fill"
        case .rewarded: return "rosette"
        }
    }

    @ViewBuilder
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Placeholder contribución").font(.body.weight(.semibold))
            Text("Placeholder descripción").font(.subheadline).foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }
}
