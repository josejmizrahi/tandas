import SwiftUI
import RuulCore

/// Form-based editor for a single role. Drives `create_custom_role(...)`
/// in create mode and `update_role_permissions(...)` in edit mode.
/// System roles open here read-only (Save is disabled and a hint is
/// shown); backend would raise on mutation anyway.
public struct RoleEditorView: View {
    @Bindable var store: RolesStore
    let groupId: UUID

    @State private var isSaving: Bool = false

    public init(store: RolesStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        NavigationStack {
            Form {
                if isSystemRole {
                    Section {
                        Label(L10n.Roles.systemReadOnlyHint, systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                identitySection
                if !store.isEditingExisting {
                    keySection
                }
                permissionsSection
                if let message = store.draftErrorMessage, !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(store.isEditingExisting ? L10n.Roles.editTitle : L10n.Roles.createTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: L10n.Roles.cancel)) {
                        store.isEditorPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.Roles.save)) {
                        save()
                    }
                    .disabled(!store.canSaveDraft || isSaving || isSystemRole)
                }
            }
            .alert(
                "Se abrió una votación",
                isPresented: governanceDecisionOpenedBinding,
                presenting: governanceDecisionOpenedFromOutcome
            ) { _ in
                Button("Entendido", role: .cancel) { store.clearGovernanceOutcome() }
            } message: { _ in
                Text("Modificar roles cambia la estructura de autoridad del grupo y es una decisión constitucional. Se aplicará cuando pase la votación.")
            }
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
    private var identitySection: some View {
        Section(L10n.Roles.nameLabel) {
            TextField(
                String(localized: L10n.Roles.namePlaceholder),
                text: $store.draftName
            )
            .disabled(isSystemRole)
            TextField(
                String(localized: L10n.Roles.descriptionPlaceholder),
                text: $store.draftDescription,
                axis: .vertical
            )
            .lineLimit(2...5)
            .disabled(isSystemRole)
        }
    }

    @ViewBuilder
    private var keySection: some View {
        Section {
            TextField(
                String(localized: L10n.Roles.keyPlaceholder),
                text: $store.draftKey
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
            Text(L10n.Roles.keyLabel)
        } footer: {
            Text(L10n.Roles.keyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        let groups = store.catalogByCategory
        if groups.isEmpty {
            Section(L10n.Roles.permissionsSection) {
                Text(L10n.Roles.permissionsEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(groups, id: \.0) { (category, entries) in
                Section {
                    ForEach(entries) { entry in
                        permissionRow(entry: entry)
                    }
                } header: {
                    categoryHeader(category, entries: entries)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionRow(entry: PermissionCatalogEntry) -> some View {
        Button {
            guard !isSystemRole else { return }
            store.togglePermission(entry.key)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.description)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(entry.key)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if store.draftPermissions.contains(entry.key) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSystemRole)
    }

    @ViewBuilder
    private func categoryHeader(_ category: PermissionCategory, entries: [PermissionCatalogEntry]) -> some View {
        HStack {
            Label(category.label, systemImage: category.systemImageName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if !isSystemRole {
                let selection = store.categorySelectionState(category)
                switch selection {
                case .all:
                    Button(String(localized: L10n.Roles.allOffAction)) {
                        store.toggleCategory(category, selectAll: false)
                    }
                    .font(.caption.weight(.medium))
                case .none, .partial:
                    Button(String(localized: L10n.Roles.allOnAction)) {
                        store.toggleCategory(category, selectAll: true)
                    }
                    .font(.caption.weight(.medium))
                case .empty:
                    EmptyView()
                }
            }
        }
    }

    private var isSystemRole: Bool {
        guard let id = store.editorRoleId else { return false }
        return store.roles.first(where: { $0.id == id })?.isSystem ?? false
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
