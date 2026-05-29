import SwiftUI
import RuulCore

/// "Historia del grupo" — timeline neutral construido sobre `group_events`.
/// Cada acción canónica (sanción emitida, regla creada, propósito ajustado,
/// gasto registrado, etc.) ya queda anotada por `record_system_event`; esta
/// vista solo lee.
///
/// V2-G7: chip strip por categoría + búsqueda client-side sobre summary +
/// actor + event_type; tap en row genera un `DeepLink` y lo pasa al
/// shell para enfocar la primitiva correspondiente. Sin RPC nueva — todo
/// usa `entity_kind` + `entity_id` ya presentes en `group_events`.
public struct GroupHistoryView: View {
    @Bindable var store: EventsStore
    let groupId: UUID
    let onSelectEvent: ((GroupEvent) -> Void)?
    let onAskWhyDidThisHappen: ((GroupEvent) -> Void)?

    public init(
        store: EventsStore,
        groupId: UUID,
        onSelectEvent: ((GroupEvent) -> Void)? = nil,
        onAskWhyDidThisHappen: ((GroupEvent) -> Void)? = nil
    ) {
        self.store = store
        self.groupId = groupId
        self.onSelectEvent = onSelectEvent
        self.onAskWhyDidThisHappen = onAskWhyDidThisHappen
    }

    public var body: some View {
        List {
            filterStrip
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            content
        }
        .navigationTitle(L10n.History.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $store.searchQuery,
            prompt: Text(L10n.History.searchPlaceholder)
        )
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
    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(
                    label: Text(L10n.History.filterAll),
                    systemImage: "line.3.horizontal.decrease.circle",
                    isSelected: store.selectedCategory == nil
                ) {
                    store.setCategory(nil)
                }
                ForEach(HistoryCategory.allCases) { category in
                    chip(
                        label: Text(category.label),
                        systemImage: category.systemImageName,
                        isSelected: store.selectedCategory == category
                    ) {
                        store.setCategory(category)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func chip(
        label: Text,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let core = Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                label
            }
            .font(.subheadline.weight(.medium))
        }
        .controlSize(.small)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])

        if isSelected {
            core.buttonStyle(.glassProminent)
        } else {
            core.buttonStyle(.glass)
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
                ), isInteractive: false)
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
            } else if store.visibleEvents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.History.noFilteredResultsTitle).font(.headline)
                    Text(L10n.History.noFilteredResultsBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if store.hasActiveFilter {
                        Button(String(localized: L10n.History.clearFilters)) {
                            store.setCategory(nil)
                            store.searchQuery = ""
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 6)
            } else {
                ForEach(store.visibleEvents) { event in
                    row(for: event, isInteractive: onSelectEvent != nil)
                        .onAppear {
                            // Infinite-ish scroll: when the bottom row
                            // appears, try to pull the next page. Use
                            // the underlying `events` last id so the
                            // trigger fires regardless of filter state.
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
    private func row(for event: GroupEvent, isInteractive: Bool) -> some View {
        let content = HStack(alignment: .top, spacing: 12) {
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

            if isInteractive, hasDestination(for: event) {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())

        let body = Group {
            if isInteractive, hasDestination(for: event) {
                Button {
                    onSelectEvent?(event)
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }

        // V2-G8.2 — "¿Por qué pasó esto?" swipe action. Always offered
        // when the host wired the callback; the sheet itself handles
        // both engine-caused and human-caused branches.
        if let onAskWhy = onAskWhyDidThisHappen {
            body.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    onAskWhy(event)
                } label: {
                    Label("¿Por qué?", systemImage: "questionmark.circle")
                }
                .tint(.accentColor)
            }
        } else {
            body
        }
    }

    private func hasDestination(for event: GroupEvent) -> Bool {
        HistoryEventRouting.deepLink(for: event, groupId: groupId) != nil
    }
}

/// Helper that maps a `GroupEvent` to an in-app `DeepLink` based on its
/// canonical `entity_kind` + `entity_id`. Kept local to the feature so
/// `RuulCore` stays unaware of `DeepLink` (which lives in `RuulApp`).
enum HistoryEventRouting {
    static func deepLink(for event: GroupEvent, groupId: UUID) -> DeepLink? {
        guard let entityId = event.entityId else {
            // Some events anchor on the group itself (purpose, boundary,
            // decision_rules, etc.) — falling back to .group lets the
            // shell still focus the right group without an entity sheet.
            if let kind = event.entityKind?.lowercased(),
               kind == "group" || event.eventType.hasPrefix("group.") {
                return .group(groupId: groupId)
            }
            return nil
        }
        switch event.entityKind?.lowercased() {
        case "decision":
            return .decision(groupId: groupId, decisionId: entityId)
        case "sanction":
            return .sanction(groupId: groupId, sanctionId: entityId)
        case "dispute":
            return .dispute(groupId: groupId, disputeId: entityId)
        case "membership", "member":
            return .member(groupId: groupId, membershipId: entityId)
        case "mandate":
            return .mandate(groupId: groupId, mandateId: entityId)
        case "transaction", "obligation", "money_movement":
            return .money(groupId: groupId)
        default:
            return nil
        }
    }
}

