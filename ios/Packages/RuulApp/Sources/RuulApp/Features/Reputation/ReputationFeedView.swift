import SwiftUI
import RuulCore

/// Group-wide reputation feed (Primitiva 12, C4). Chronological list
/// of neutral facts the group has recorded. Doctrina firme: NO score
/// público, NO ranking, NO badges — esta vista nombra hechos, no
/// hace métrica.
public struct ReputationFeedView: View {
    @Bindable var store: ReputationFeedStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID

    public init(
        store: ReputationFeedStore,
        membersStore: MembersStore,
        groupId: UUID
    ) {
        self.store = store
        self.membersStore = membersStore
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.ReputationFeed.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginRecording()
                } label: {
                    Label(L10n.ReputationFeed.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isRecordPresented) {
            RecordReputationEventSheet(store: store, membersStore: membersStore, groupId: groupId)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
            await membersStore.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.ReputationFeed.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.ReputationFeed.retry)) {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if store.isEmpty {
                ContentUnavailableView {
                    Label(L10n.ReputationFeed.emptyTitle, systemImage: "hands.sparkles")
                } description: {
                    Text(L10n.ReputationFeed.emptyDescription)
                } actions: {
                    Button {
                        store.beginRecording()
                    } label: {
                        Text(L10n.ReputationFeed.addButton)
                    }
                    .buttonStyle(.glassProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.events) { event in
                    row(for: event)
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
                if let subject = event.subjectDisplayName, !subject.isEmpty {
                    Text(subject)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let reason = event.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    if let when = event.when {
                        Text(when, format: .dateTime.day().month().year())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let actor = event.actorDisplayName, !actor.isEmpty {
                        Text("· Registró \(actor)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var placeholderRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle").frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Placeholder kind").font(.body.weight(.semibold))
                Text("Placeholder reason que ocupa una línea.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .redacted(reason: .placeholder)
    }
}
