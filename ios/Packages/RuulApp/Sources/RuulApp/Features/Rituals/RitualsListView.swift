import SwiftUI
import RuulCore

/// Full list surface for Primitiva 21 (Ritual). Rows group rituals by
/// `RitualMarkerKind`; swipe = end. Toolbar add opens
/// `CreateRitualSheet`; tap on a row opens `EditRitualSheet`.
public struct RitualsListView: View {
    @Bindable var store: RitualsStore
    let groupId: UUID

    @State private var toEnd: GroupResourceSeries?

    public init(store: RitualsStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Rituals.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginCreating()
                } label: {
                    Label(L10n.Rituals.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isCreatePresented) {
            CreateRitualSheet(store: store, groupId: groupId)
        }
        .sheet(isPresented: $store.isEditPresented) {
            EditRitualSheet(store: store, groupId: groupId)
        }
        .confirmationDialog(
            Text(L10n.Rituals.endConfirmTitle),
            isPresented: endDialogBinding,
            titleVisibility: .visible,
            presenting: toEnd
        ) { ritual in
            Button(role: .destructive) {
                Task { _ = await store.endRitual(ritual.id, groupId: groupId) }
            } label: {
                Text(L10n.Rituals.endAction)
            }
            Button(role: .cancel) {} label: { Text(L10n.Rituals.cancel) }
        } message: { _ in
            Text(L10n.Rituals.endConfirmMessage)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.Rituals.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.Rituals.retry)) {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if !store.hasRituals {
                ContentUnavailableView {
                    Label(L10n.Rituals.emptyTitle, systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text(L10n.Rituals.emptyDescription)
                } actions: {
                    Button {
                        store.beginCreating()
                    } label: {
                        Text(L10n.Rituals.addButton)
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
        ForEach(RitualMarkerKind.selectable, id: \.self) { kind in
            let bucket = store.rituals.filter { $0.ritualMarkerKind == kind }
            if !bucket.isEmpty {
                Section {
                    ForEach(bucket) { ritual in
                        row(for: ritual)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    toEnd = ritual
                                } label: {
                                    Label(String(localized: L10n.Rituals.endButton), systemImage: "stop.circle")
                                }
                            }
                    }
                } header: {
                    Label(kind.label, systemImage: kind.systemImageName)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for ritual: GroupResourceSeries) -> some View {
        Button {
            store.beginEditing(ritual)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ritual.ritualMeaning ?? String(localized: L10n.Rituals.markerNone))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(ritual.cadence.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                }
                if let startsOn = ritual.startsOn {
                    Text("\(String(localized: L10n.Rituals.startsOnLabel)) \(startsOn.formatted(.dateTime.day().month().year()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let endsOn = ritual.endsOn {
                    Text("\(String(localized: L10n.Rituals.endsOnLabel)) \(endsOn.formatted(.dateTime.day().month().year()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var endDialogBinding: Binding<Bool> {
        Binding(
            get: { toEnd != nil },
            set: { if !$0 { toEnd = nil } }
        )
    }

    @ViewBuilder
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Placeholder ritual").font(.body.weight(.semibold))
            Text("Placeholder cadence").font(.caption).foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
    }
}
