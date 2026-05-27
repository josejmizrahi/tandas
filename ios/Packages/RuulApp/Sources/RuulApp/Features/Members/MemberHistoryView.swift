import SwiftUI
import RuulCore

/// "Historial en este grupo" — neutral list of reputation events for
/// a single member. Doctrina: sin score, sin badges, sin ranking.
/// Cada fila nombra el hecho (kind) + fecha + razón opcional.
public struct MemberHistoryView: View {
    @Bindable var store: ReputationStore
    let groupId: UUID
    let memberItem: MembershipBoundaryItem

    public init(store: ReputationStore,
                groupId: UUID,
                memberItem: MembershipBoundaryItem) {
        self.store = store
        self.groupId = groupId
        self.memberItem = memberItem
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Reputation.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if let mid = memberItem.membershipId {
                await store.refresh(groupId: groupId, subjectMembershipId: mid)
            }
        }
        .task {
            if let mid = memberItem.membershipId {
                await store.refreshIfNeeded(groupId: groupId, subjectMembershipId: mid)
            }
        }
        .onDisappear {
            store.clear()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in
                placeholderRow
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Reputation.errorTitle)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(String(localized: L10n.Reputation.retry)) {
                    Task {
                        if let mid = memberItem.membershipId {
                            await store.refresh(groupId: groupId, subjectMembershipId: mid)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        case .loaded:
            if store.isEmpty {
                emptyState
            } else {
                Section(memberItem.displayName) {
                    ForEach(store.events) { event in
                        row(for: event)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for event: GroupReputationEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.kind.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if let reason = event.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let when = event.when {
                    Text(when, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Reputation.emptyTitle)
                .font(.headline)
            Text(L10n.Reputation.emptyDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var placeholderRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle")
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Placeholder kind").font(.body.weight(.semibold))
                Text("Placeholder reason that takes a line of width.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
    }
}
