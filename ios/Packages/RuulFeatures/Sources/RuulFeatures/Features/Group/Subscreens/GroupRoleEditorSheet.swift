import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Per-role editor invoked from `GroupRolesSheet`. Handles both
/// "create new" (`existing == nil`) and "edit existing". Writes through
/// `upsert_group_role` (mig 00230). The server enforces the
/// founder-keeps-`assignRoles` lockout safeguard and the id format —
/// the UI mirrors the same validation up-front for responsive feedback.
@MainActor
public struct GroupRoleEditorSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let existing: RoleDefinition?
    public let onClose: (RoleDefinition?) async -> Void

    @State private var roleId: String
    @State private var label: String
    @State private var selected: Set<Permission>
    @State private var maxHoldersOn: Bool
    @State private var maxHolders: Int
    @State private var saving: Bool = false
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "roles.editor")

    public init(
        groupId: UUID,
        existing: RoleDefinition?,
        onClose: @escaping (RoleDefinition?) async -> Void
    ) {
        self.groupId = groupId
        self.existing = existing
        self.onClose = onClose
        _roleId       = State(initialValue: existing?.id ?? "")
        _label        = State(initialValue: existing?.label ?? "")
        _selected     = State(initialValue: Set(existing?.permissions ?? []))
        _maxHoldersOn = State(initialValue: existing?.maxHolders != nil)
        _maxHolders   = State(initialValue: existing?.maxHolders ?? 1)
    }

    private var isEditingSystem: Bool { existing?.system == true }
    private var isCreating: Bool { existing == nil }

    private var navigationTitle: String {
        if isCreating { return "Nuevo rol" }
        if isEditingSystem { return existing?.humanLabel ?? "Rol del sistema" }
        return "Editar rol"
    }

    public var body: some View {
        NavigationStack {
            Form {
                if isCreating {
                    idSection
                } else {
                    Section {
                        infoRow("Identificador", value: existing?.id ?? "")
                        if isEditingSystem {
                            Text("Los roles del sistema no se pueden eliminar, pero puedes ajustar sus permisos.")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }

                if !isEditingSystem {
                    Section("Nombre visible") {
                        TextField("p. ej. Tesorero", text: $label)
                            .textInputAutocapitalization(.words)
                    }
                }

                permissionsSection
                if !isEditingSystem {
                    maxHoldersSection
                }
                if let error {
                    Section { Text(error).foregroundStyle(Color.red) }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        Task {
                            dismiss()
                            await onClose(nil)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Guardando…" : "Guardar") {
                        Task { await save() }
                    }
                    .disabled(!canSave || saving)
                }
            }
        }
    }

    // MARK: - Sections

    private var idSection: some View {
        Section {
            TextField("identificador", text: $roleId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Text("Solo letras minúsculas, números y guiones bajos. Empieza con una letra. Ejemplos: `treasurer`, `seat_owner`, `lifeguard`.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        } header: {
            Text("Identificador")
        }
    }

    private var permissionsSection: some View {
        ForEach(Permission.Category.allCases, id: \.self) { category in
            let perms = Permission.knownCases.filter { $0.category == category }
            if !perms.isEmpty {
                Section(category.title) {
                    ForEach(perms, id: \.self) { perm in
                        permissionRow(perm)
                    }
                }
            }
        }
    }

    private var maxHoldersSection: some View {
        Section {
            Toggle("Limitar cuántos miembros lo tienen", isOn: $maxHoldersOn)
            if maxHoldersOn {
                Stepper(value: $maxHolders, in: 1...50) {
                    HStack {
                        Text("Máximo")
                        Spacer()
                        Text("\(maxHolders)")
                            .foregroundStyle(Color.ruulTextAccent)
                    }
                }
            }
        } header: {
            Text("Cantidad")
        } footer: {
            Text("Útil para roles como Tesorero o Capitán que solo una o dos personas deben tener.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private func permissionRow(_ permission: Permission) -> some View {
        let bound = Binding(
            get: { selected.contains(permission) },
            set: { isOn in
                if isOn { selected.insert(permission) }
                else    { selected.remove(permission) }
            }
        )
        Toggle(isOn: bound) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.humanLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                Text(permission.hint)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .disabled(isFounderAssignRolesLock(permission))
    }

    @ViewBuilder
    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            Text(value).foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Validation

    private static let idPattern = #"^[a-z][a-z0-9_]{0,31}$"#

    private var canSave: Bool {
        guard !saving else { return false }
        if isCreating {
            let trimmed = roleId.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: Self.idPattern, options: .regularExpression) != nil else {
                return false
            }
        }
        return true
    }

    /// Founder MUST retain `assignRoles` — disables the toggle for the
    /// founder role in that one specific case so the founder cannot
    /// accidentally lock the group out.
    private func isFounderAssignRolesLock(_ permission: Permission) -> Bool {
        guard let existing, existing.id == "founder", permission == .assignRoles else {
            return false
        }
        return true
    }

    // MARK: - Save

    private func save() async {
        guard canSave else { return }
        let normalizedId: String
        if let existing {
            normalizedId = existing.id
        } else {
            normalizedId = roleId.trimmingCharacters(in: .whitespaces).lowercased()
        }

        var perms = selected
        // Belt-and-suspenders: even if the toggle is disabled, encode
        // the safeguard client-side so an aborted UI state can't omit
        // assignRoles from the payload.
        if normalizedId == "founder" { perms.insert(.assignRoles) }

        saving = true
        error = nil
        defer { saving = false }
        do {
            let saved = try await app.groupsRepo.upsertGroupRole(
                groupId: groupId,
                roleId: normalizedId,
                label: label.isEmpty ? nil : label,
                permissions: Array(perms).sorted { $0.rawString < $1.rawString },
                maxHolders: maxHoldersOn ? maxHolders : nil
            )
            let updatedRole = saved.effectiveRoles[normalizedId]
            dismiss()
            await onClose(updatedRole)
        } catch {
            log.warning("upsert_group_role failed: \(error.localizedDescription, privacy: .public)")
            self.error = "No pudimos guardar el rol: \(error.localizedDescription)"
        }
    }
}
