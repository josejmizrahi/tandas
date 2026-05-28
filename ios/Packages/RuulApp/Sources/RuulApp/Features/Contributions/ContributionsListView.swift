import SwiftUI
import RuulCore

/// Full list of contributions (Primitiva 9) for a group. Grouped by
/// `contribution_type` in canonical display order. Toolbar add =
/// log self-claim. Read-only beyond logging — verify lands later.
public struct ContributionsListView: View {
    @Bindable var store: ContributionsStore
    let groupId: UUID
    /// Optional filters threaded into the read RPC. nil = group-wide.
    let filterMembershipId: UUID?
    let filterResourceId: UUID?

    public init(
        store: ContributionsStore,
        groupId: UUID,
        filterMembershipId: UUID? = nil,
        filterResourceId: UUID? = nil
    ) {
        self.store = store
        self.groupId = groupId
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
        .task {
            await store.refreshIfNeeded(groupId: groupId, membershipId: filterMembershipId, resourceId: filterResourceId)
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
                if contribution.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
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
                        .background(Capsule().fill(Color.gray.opacity(0.12)))
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
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Placeholder contribución").font(.body.weight(.semibold))
            Text("Placeholder descripción").font(.subheadline).foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }
}
