import SwiftUI
import RuulCore

/// Primitiva 2 (Boundary) policy surface. Read view summarising the
/// active policy; toolbar "Cambiar" opens the inline edit sheet that
/// drives `set_group_boundary_policy(...)`.
public struct BoundaryPolicyView: View {
    @Bindable var store: BoundaryPolicyStore
    let groupId: UUID

    public init(store: BoundaryPolicyStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            switch store.phase {
            case .idle, .loading:
                placeholderSection
            case .failed(let message):
                errorSection(message: message)
            case .loaded:
                if let policy = store.policy {
                    loadedContent(policy: policy)
                } else {
                    placeholderSection
                }
            }
        }
        .navigationTitle(L10n.BoundaryPolicy.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.beginEditing()
                } label: {
                    Text(L10n.BoundaryPolicy.editButton)
                }
                .disabled(store.policy == nil)
            }
        }
        .sheet(isPresented: $store.isEditPresented) {
            EditBoundaryPolicySheet(store: store, groupId: groupId)
        }
        .alert(
            "Se abrió una votación",
            isPresented: governanceDecisionOpenedBinding,
            presenting: governanceDecisionOpenedFromOutcome
        ) { _ in
            Button("Entendido", role: .cancel) { store.clearGovernanceOutcome() }
        } message: { _ in
            Text("Cambiar la política de entrada del grupo es una decisión constitucional. Se aplicará cuando pase la votación.")
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
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

    @ViewBuilder
    private func loadedContent(policy: GroupBoundaryPolicy) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.BoundaryPolicy.headline)
                    .font(.headline)
                if policy.isDefault {
                    Text(L10n.BoundaryPolicy.isDefaultHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }

        Section(L10n.BoundaryPolicy.entrySection) {
            policyRow(
                label: policy.entryMode.label,
                subtitle: policy.entryMode.subtitle,
                systemImage: policy.entryMode.systemImageName
            )
        }

        Section(L10n.BoundaryPolicy.inviterSection) {
            policyRow(
                label: policy.whoCanInvite.label,
                subtitle: policy.whoCanInvite.subtitle,
                systemImage: "person.crop.circle.badge.plus"
            )
        }

        Section(L10n.BoundaryPolicy.approvalSection) {
            HStack {
                Label(L10n.BoundaryPolicy.approvalLabel, systemImage: "checkmark.shield")
                Spacer()
                Image(systemName: policy.requiresApproval ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(policy.requiresApproval ? Color.accentColor : Color.secondary)
            }
            Text(L10n.BoundaryPolicy.approvalHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(L10n.BoundaryPolicy.exitSection) {
            policyRow(
                label: policy.exitMode.label,
                subtitle: policy.exitMode.subtitle,
                systemImage: "rectangle.portrait.and.arrow.right"
            )
        }

        if let notes = policy.trimmedNotes {
            Section(L10n.BoundaryPolicy.notesSection) {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private func policyRow(
        label: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var placeholderSection: some View {
        Section {
            HStack {
                ProgressView()
                Text("Cargando…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func errorSection(message: String) -> some View {
        Section {
            ContentUnavailableView {
                Label(L10n.BoundaryPolicy.errorTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: L10n.BoundaryPolicy.retry)) {
                    Task { await store.refresh(groupId: groupId) }
                }
            }
        }
    }
}

private struct EditBoundaryPolicySheet: View {
    @Bindable var store: BoundaryPolicyStore
    let groupId: UUID

    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                entrySection
                inviterSection
                approvalSection
                exitSection
                notesSection
                if let message = store.draftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.BoundaryPolicy.editTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.BoundaryPolicy.cancel)) {
                        store.isEditPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.BoundaryPolicy.save)) {
                        save()
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var entrySection: some View {
        Section(L10n.BoundaryPolicy.entrySection) {
            ForEach(BoundaryEntryMode.displayOrder) { mode in
                Button {
                    store.draftEntryMode = mode
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(mode.label, systemImage: mode.systemImageName)
                                .font(.body)
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.draftEntryMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var inviterSection: some View {
        Section(L10n.BoundaryPolicy.inviterSection) {
            ForEach(BoundaryInviterScope.displayOrder) { scope in
                Button {
                    store.draftWhoCanInvite = scope
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scope.label).font(.body)
                            Text(scope.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.draftWhoCanInvite == scope {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var approvalSection: some View {
        Section {
            Toggle(isOn: $store.draftRequiresApproval) {
                Text(L10n.BoundaryPolicy.approvalLabel)
            }
        } footer: {
            Text(L10n.BoundaryPolicy.approvalHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var exitSection: some View {
        Section(L10n.BoundaryPolicy.exitSection) {
            ForEach(BoundaryExitMode.displayOrder) { mode in
                Button {
                    store.draftExitMode = mode
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.label).font(.body)
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.draftExitMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        Section(L10n.BoundaryPolicy.notesSection) {
            TextField(
                String(localized: L10n.BoundaryPolicy.notesPlaceholder),
                text: $store.draftNotes,
                axis: .vertical
            )
            .lineLimit(3...8)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            _ = await store.saveDraft(groupId: groupId)
            isSaving = false
        }
    }
}
