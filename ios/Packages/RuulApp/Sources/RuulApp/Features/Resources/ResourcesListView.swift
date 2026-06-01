import SwiftUI
import RuulCore

/// Full list of active resources, grouped by type. Pushed from
/// `GroupHomeView` via NavigationLink. Toolbar add button opens
/// `CreateResourceView`; rows expose context-menu archive with a
/// confirmation dialog.
public struct ResourcesListView: View {
    @Bindable var store: ResourcesStore
    @Bindable var membersStore: MembersStore
    @Bindable var calendarEventsStore: CalendarEventsStore
    let groupId: UUID
    let permissionsFetcher: (UUID) async throws -> [String]

    @State private var toArchive: GroupResource?

    public init(
        store: ResourcesStore,
        membersStore: MembersStore,
        calendarEventsStore: CalendarEventsStore,
        groupId: UUID,
        permissionsFetcher: @escaping (UUID) async throws -> [String] = { _ in [] }
    ) {
        self.store = store
        self.membersStore = membersStore
        self.calendarEventsStore = calendarEventsStore
        self.groupId = groupId
        self.permissionsFetcher = permissionsFetcher
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Resources.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginCreating()
                } label: {
                    Label(L10n.Resources.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isCreatePresented) {
            CreateResourceView(
                store: store,
                calendarEventsStore: calendarEventsStore,
                groupId: groupId
            )
        }
        .navigationDestination(for: GroupResource.self) { resource in
            ResourceDetailView(
                store: store,
                membersStore: membersStore,
                groupId: groupId,
                resource: resource,
                permissionsFetcher: permissionsFetcher
            )
        }
        .confirmationDialog(
            Text(L10n.Resources.archiveConfirmTitle),
            isPresented: archiveDialogBinding,
            titleVisibility: .visible,
            presenting: toArchive
        ) { resource in
            Button(role: .destructive) {
                Task { await store.archive(resourceId: resource.id, reason: nil, groupId: groupId) }
            } label: {
                Text(L10n.Resources.archive)
            }
            Button(role: .cancel) {} label: { Text(L10n.Resources.cancel) }
        } message: { _ in
            Text(L10n.Resources.archiveConfirmMessage)
        }
        .alert(
            "Se abrió una votación",
            isPresented: decisionOpenedBinding,
            presenting: decisionOpenedFromOutcome
        ) { _ in
            Button("Entendido", role: .cancel) { store.clearGovernanceOutcome() }
        } message: { details in
            Text("Esta acción requiere decisión grupal. Se ejecutará cuando pase la votación.")
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    /// Binds `lastGovernanceOutcome` to a Bool for `.alert(isPresented:)`.
    private var decisionOpenedBinding: Binding<Bool> {
        Binding(
            get: { decisionOpenedFromOutcome != nil },
            set: { newValue in
                if !newValue { store.clearGovernanceOutcome() }
            }
        )
    }

    private var decisionOpenedFromOutcome: DecisionOpenedDetails? {
        if case .decisionOpened(let details) = store.lastGovernanceOutcome {
            return details
        }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            if store.resources.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    ResourceRowView(resource: GroupResource(
                        id: UUID(), groupId: groupId,
                        resourceType: .other,
                        name: "Placeholder",
                        description: "Loading description…"
                    ))
                    .redacted(reason: .placeholder)
                }
            } else {
                loadedSections
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.Resources.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if store.resources.isEmpty {
                ContentUnavailableView {
                    Label(L10n.Resources.emptyTitle, systemImage: "square.stack.3d.up")
                } description: {
                    Text(L10n.Resources.emptyDescription)
                } actions: {
                    Button {
                        store.beginCreating()
                    } label: {
                        Text(L10n.Resources.addButton)
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
        ForEach(GroupResourceType.displayOrder, id: \.self) { type in
            if let bucket = store.resourcesByType[type], !bucket.isEmpty {
                Section {
                    ForEach(bucket) { resource in
                        NavigationLink(value: resource) {
                            ResourceRowView(resource: resource)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                toArchive = resource
                            } label: {
                                Label(L10n.Resources.archive, systemImage: "archivebox")
                            }
                        }
                    }
                } header: {
                    Text(type.label)
                }
            }
        }
    }

    private var archiveDialogBinding: Binding<Bool> {
        Binding(
            get: { toArchive != nil },
            set: { newValue in if !newValue { toArchive = nil } }
        )
    }
}
