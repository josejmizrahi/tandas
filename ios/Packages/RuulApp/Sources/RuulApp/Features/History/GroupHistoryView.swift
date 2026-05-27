import SwiftUI
import RuulCore

/// "Historia del grupo" — timeline neutral construido sobre `group_events`.
/// Cada acción canónica (sanción emitida, regla creada, propósito ajustado,
/// gasto registrado, etc.) ya queda anotada por `record_system_event`; esta
/// vista solo lee.
///
/// Doctrina (Plan §B13): cada superficie principal anota el "por qué". Foundation
/// muestra el feed crudo — categorización editorial es un slice posterior.
public struct GroupHistoryView: View {
    @Bindable var store: EventsStore
    let groupId: UUID

    public init(store: EventsStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.History.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
        .onDisappear {
            store.clear()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<4, id: \.self) { _ in
                row(for: GroupEvent(
                    id: UUID(), groupId: groupId,
                    eventType: "placeholder.placeholder",
                    summary: "Placeholder summary line that takes a width."
                ))
                .redacted(reason: .placeholder)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Reintentar") {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .padding(.vertical, 6)
        case .loaded:
            if store.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.History.emptyTitle).font(.headline)
                    Text(L10n.History.emptyDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(store.events) { event in
                    row(for: event)
                        .onAppear {
                            // Infinite-ish scroll: when the bottom row
                            // appears, try to pull the next page.
                            if event.id == store.events.last?.id, !store.reachedEnd {
                                Task { await store.loadMore(groupId: groupId) }
                            }
                        }
                }
                if store.isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for event: GroupEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                if let summary = event.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                } else {
                    Text(event.eventType)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if let actor = event.actorDisplayName {
                        Text(actor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let when = event.occurredAt {
                        Text(when, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
