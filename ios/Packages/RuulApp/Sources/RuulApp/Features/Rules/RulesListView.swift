import SwiftUI
import RuulCore

/// Full list of active rules for a group. Pushed from `GroupHomeView`
/// onto the existing `NavigationStack`. Toolbar add button opens
/// `EditRuleView`; rows expose a context-menu archive action with a
/// confirmation dialog so swipes don't fire by accident.
public struct RulesListView: View {
    @Bindable var store: RulesStore
    let groupId: UUID

    @State private var ruleToArchive: GroupRule?

    public init(store: RulesStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            content
        }
        .navigationTitle(L10n.Rules.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginCreating()
                } label: {
                    Label(L10n.Rules.addButton, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $store.isCreatePresented) {
            EditRuleView(store: store, groupId: groupId)
        }
        .confirmationDialog(
            Text(L10n.Rules.archiveConfirmTitle),
            isPresented: archiveDialogBinding,
            titleVisibility: .visible,
            presenting: ruleToArchive
        ) { rule in
            Button(role: .destructive) {
                Task { await store.archive(ruleId: rule.id, reason: nil, groupId: groupId) }
            } label: {
                Text(L10n.Rules.archive)
            }
            Button(role: .cancel) {} label: { Text(L10n.Rules.cancel) }
        } message: { _ in
            Text(L10n.Rules.archiveConfirmMessage)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            if store.rules.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    RuleRowView(rule: GroupRule(
                        id: UUID(), groupId: groupId,
                        title: "Placeholder", body: "Loading rule body…",
                        ruleType: .norm, severity: 1
                    ))
                    .redacted(reason: .placeholder)
                }
            } else {
                loadedSection
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.Rules.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if store.rules.isEmpty {
                ContentUnavailableView {
                    Label(L10n.Rules.emptyTitle, systemImage: "list.bullet.rectangle")
                } description: {
                    Text(L10n.Rules.emptyDescription)
                } actions: {
                    Button {
                        store.beginCreating()
                    } label: {
                        Text(L10n.Rules.addButton)
                    }
                    .buttonStyle(.glassProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                loadedSection
            }
        }
    }

    @ViewBuilder
    private var loadedSection: some View {
        Section {
            ForEach(store.rules) { rule in
                RuleRowView(rule: rule)
                    .contextMenu {
                        Button(role: .destructive) {
                            ruleToArchive = rule
                        } label: {
                            Label(L10n.Rules.archive, systemImage: "archivebox")
                        }
                    }
            }
        }
    }

    private var archiveDialogBinding: Binding<Bool> {
        Binding(
            get: { ruleToArchive != nil },
            set: { newValue in if !newValue { ruleToArchive = nil } }
        )
    }
}
