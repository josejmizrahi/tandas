import SwiftUI
import RuulCore

/// B7 — Group-level visibility picker. Tap a row to switch
/// `groups.visibility`. Backend gates by `group.update`; non-admins
/// see a permission error and the local state reverts.
public struct GroupPrivacyView: View {
    @Bindable var store: PrivacyStore
    let groupId: UUID

    public init(store: PrivacyStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            switch store.phase {
            case .idle, .loading:
                Section {
                    HStack { ProgressView(); Text("Cargando…").foregroundStyle(.secondary) }
                }
            case .failed(let message):
                Section {
                    ContentUnavailableView {
                        Label(L10n.Privacy.errorTitle, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button(String(localized: L10n.Privacy.retry)) {
                            Task { await store.refresh(groupId: groupId) }
                        }
                    }
                }
            case .loaded:
                Section {
                    Text(L10n.Privacy.headline).font(.headline)
                }
                Section(L10n.Privacy.visibilitySection) {
                    ForEach(GroupVisibility.displayOrder) { visibility in
                        Button {
                            Task { _ = await store.setVisibility(visibility, groupId: groupId) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: visibility.systemImageName)
                                    .foregroundStyle(.tint)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(visibility.label)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(visibility.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.visibility == visibility {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let message = store.errorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(L10n.Privacy.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
        .alert(
            "Se abrió una votación",
            isPresented: governanceDecisionOpenedBinding,
            presenting: governanceDecisionOpenedFromOutcome
        ) { _ in
            Button("Entendido", role: .cancel) { store.clearGovernanceOutcome() }
        } message: { _ in
            Text("Cambiar la visibilidad del grupo es una decisión constitucional. Se aplicará cuando pase la votación.")
        }
    }

    private var governanceDecisionOpenedBinding: Binding<Bool> {
        Binding(
            get: { governanceDecisionOpenedFromOutcome != nil },
            set: { newValue in
                if !newValue { store.clearGovernanceOutcome() }
            }
        )
    }

    private var governanceDecisionOpenedFromOutcome: DecisionOpenedDetails? {
        if case .decisionOpened(let details) = store.lastGovernanceOutcome {
            return details
        }
        return nil
    }
}
