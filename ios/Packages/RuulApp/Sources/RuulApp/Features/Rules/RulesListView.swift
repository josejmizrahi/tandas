import SwiftUI
import RuulCore

/// Full list of active rules for a group. Pushed from `GroupHomeView`
/// onto the existing `NavigationStack`. Toolbar add button offers
/// both text and engine drafting modes (V2-G3.1); rows expose a
/// context-menu archive action with a confirmation dialog so swipes
/// don't fire by accident.
public struct RulesListView: View {
    @Bindable var store: RulesStore
    @Bindable var evaluationsStore: RuleEvaluationsStore
    let groupId: UUID

    @State private var ruleToArchive: GroupRule?
    @State private var engineRuleToArchive: EngineRule?
    @State private var showsEvaluations: Bool = false

    public init(
        store: RulesStore,
        evaluationsStore: RuleEvaluationsStore,
        groupId: UUID
    ) {
        self.store = store
        self.evaluationsStore = evaluationsStore
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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showsEvaluations = true
                } label: {
                    Label("Disparos", systemImage: "bolt.horizontal.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        store.beginCreating(mode: .text)
                    } label: {
                        Label("Regla en texto", systemImage: "text.alignleft")
                    }
                    Button {
                        store.beginCreating(mode: .engine)
                    } label: {
                        Label("Regla con engine", systemImage: "bolt.horizontal.circle")
                    }
                } label: {
                    Label(L10n.Rules.addButton, systemImage: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showsEvaluations) {
            RuleEvaluationsView(store: evaluationsStore, groupId: groupId)
        }
        .sheet(isPresented: $store.isCreatePresented) {
            EditRuleView(store: store, groupId: groupId)
        }
        .confirmationDialog(
            Text(L10n.Rules.archiveConfirmTitle),
            isPresented: textArchiveDialogBinding,
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
        .confirmationDialog(
            Text(L10n.Rules.archiveConfirmTitle),
            isPresented: engineArchiveDialogBinding,
            titleVisibility: .visible,
            presenting: engineRuleToArchive
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
            if store.rules.isEmpty && store.engineRules.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    RuleRowView(rule: GroupRule(
                        id: UUID(), groupId: groupId,
                        title: "Placeholder", body: "Loading rule body…",
                        ruleType: .norm, severity: 1
                    ))
                    .redacted(reason: .placeholder)
                }
            } else {
                loadedSections
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
            if store.rules.isEmpty && store.engineRules.isEmpty {
                ContentUnavailableView {
                    Label(L10n.Rules.emptyTitle, systemImage: "list.bullet.rectangle")
                } description: {
                    Text(L10n.Rules.emptyDescription)
                } actions: {
                    Button {
                        store.beginCreating(mode: .text)
                    } label: {
                        Text(L10n.Rules.addButton)
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
        if !store.rules.isEmpty {
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
            } header: {
                if !store.engineRules.isEmpty {
                    Text("En texto")
                }
            }
        }
        if !store.engineRules.isEmpty {
            Section {
                ForEach(store.engineRules) { rule in
                    NavigationLink {
                        EngineRuleDetailView(
                            rule: rule,
                            evaluationsStore: evaluationsStore,
                            groupId: groupId
                        )
                    } label: {
                        EngineRuleRowView(rule: rule)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            engineRuleToArchive = rule
                        } label: {
                            Label(L10n.Rules.archive, systemImage: "archivebox")
                        }
                    }
                }
            } header: {
                Text("Con engine")
            } footer: {
                Text("Estas reglas se evalúan cuando ocurre el evento. Tap para ver los disparos recientes de cada una.")
            }
        }
    }

    private var textArchiveDialogBinding: Binding<Bool> {
        Binding(
            get: { ruleToArchive != nil },
            set: { newValue in if !newValue { ruleToArchive = nil } }
        )
    }

    private var engineArchiveDialogBinding: Binding<Bool> {
        Binding(
            get: { engineRuleToArchive != nil },
            set: { newValue in if !newValue { engineRuleToArchive = nil } }
        )
    }
}

/// Compact row for an engine rule. Surfaces the trigger event +
/// the wired consequences so the rule reads as a single sentence
/// even before tapping in.
private struct EngineRuleRowView: View {
    let rule: EngineRule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.tint)
                Text(rule.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("·\(rule.severity)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let trigger = rule.triggerEventType {
                Text("Cuando: \(trigger)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let condition = rule.condition {
                Text("Si: \(condition.kind)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !rule.consequences.isEmpty {
                Text("Entonces: \(rule.consequences.map(\.kind).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Regla con engine: \(rule.title)"))
    }
}
