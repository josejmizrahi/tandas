import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Founder-managed catalog editor for `groups.roles` (Phase 5 — RolesV2).
/// Lists every role declared on the group, with system roles (`founder`,
/// `member`) pinned to the top and non-deletable. Tapping a row opens
/// `GroupRoleEditorSheet`, which lets the founder rename the role, toggle
/// permissions, and set `max_holders`. Adding is the same editor with an
/// empty `roleId` slot.
///
/// Gating: the parent view only presents this sheet when the actor has
/// `assignRoles`; the sheet itself does not re-check (server is the
/// authoritative gate via `upsert_group_role` / `delete_group_role`).
@MainActor
public struct GroupRolesSheet: View {
    @Environment(AppState.self) private var app

    public let groupId: UUID

    @State private var editing: EditingTarget?
    @State private var deletingRole: RoleDefinition?
    @State private var saving: Bool = false
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "roles.catalog")

    public init(groupId: UUID) { self.groupId = groupId }

    private var group: RuulCore.Group? {
        app.groups.first(where: { $0.id == groupId })
    }

    private var sortedRoles: [RoleDefinition] {
        let roles = group?.effectiveRoles ?? RoleDefinition.v1SystemRoles
        return roles.values.sorted { lhs, rhs in
            if lhs.system != rhs.system { return lhs.system }      // system first
            if lhs.id == "founder" { return true }
            if rhs.id == "founder" { return false }
            if lhs.id == "member"  { return true }
            if rhs.id == "member"  { return false }
            return lhs.humanLabel.localizedStandardCompare(rhs.humanLabel) == .orderedAscending
        }
    }

    public var body: some View {
        content
            .navigationTitle("Roles y permisos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = .init(role: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Crear rol")
                    .disabled(saving)
                }
            }
            .fullScreenCover(item: $editing) { target in
                GroupRoleEditorSheet(
                    groupId: groupId,
                    existing: target.role
                ) { saved in
                    editing = nil
                    if saved != nil { await app.refreshProfileAndGroups() }
                }
                .environment(app)
            }
            .alert(
                "Eliminar este rol",
                isPresented: deleteAlertBinding,
                presenting: deletingRole
            ) { role in
                Button("Eliminar", role: .destructive) {
                    Task { await delete(role) }
                }
                Button("Cancelar", role: .cancel) {
                    deletingRole = nil
                }
            } message: { role in
                Text("«\(role.humanLabel)» se quitará del catálogo del grupo y de cada miembro que lo tenga asignado.")
            }
    }

    @ViewBuilder
    private var content: some View {
        let roles = sortedRoles
        let existingIds = Set(roles.map(\.id))
        let availablePresets = RolePreset.allCases.filter { !existingIds.contains($0.roleId) }
        List {
            if !availablePresets.isEmpty {
                Section {
                    ForEach(availablePresets, id: \.roleId) { preset in
                        Button {
                            Task { await createFromPreset(preset) }
                        } label: {
                            presetRow(preset)
                        }
                        .buttonStyle(.plain)
                        .disabled(saving)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                        Text("PLANTILLAS RÁPIDAS")
                            .font(.footnote.weight(.semibold))
                        Text("Crea un rol común en 1 tap con permisos pre-armados. Después puedes editarlos.")
                            .font(.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    .textCase(nil)
                }
            }
            Section {
                ForEach(roles, id: \.id) { role in
                    Button {
                        editing = .init(role: role)
                    } label: {
                        roleRow(role)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if !role.system {
                            Button(role: .destructive) {
                                deletingRole = role
                            } label: {
                                Label("Eliminar", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                    Text("Este es el catálogo de roles del grupo: qué roles existen y qué permisos otorga cada uno.")
                    Text("Para asignar un rol a una persona, ve a Miembros → tap en el miembro → \"Editar\" en sus roles.")
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .font(.caption)
                .foregroundStyle(Color.ruulTextSecondary)
                .textCase(nil)
            } footer: {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.ruulNegative)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Quick-create row para presets de roles. Tap → crea el role con
    /// los permisos pre-armados. UXJourney P1 — antes el founder
    /// tenía que entender los 32 permisos granulares para crear su
    /// primer rol custom; ahora pasa por el atajo común.
    private func presetRow(_ preset: RolePreset) -> some View {
        HStack(spacing: RuulSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.ruulAccent.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: preset.icon)
                    .font(.footnote)
                    .foregroundStyle(Color.ruulAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.label)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color.ruulAccent)
                .accessibilityHidden(true)
        }
        .padding(.vertical, RuulSpacing.xxs)
        .accessibilityLabel("Crear rol \(preset.label) con \(preset.permissions.count) permisos")
    }

    private func createFromPreset(_ preset: RolePreset) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await app.groupsRepo.upsertGroupRole(
                groupId: groupId,
                roleId: preset.roleId,
                label: preset.label,
                permissions: preset.permissions,
                maxHolders: nil
            )
            await app.refreshProfileAndGroups()
        } catch {
            log.warning("upsert preset role failed: \(error.localizedDescription, privacy: .public)")
            self.error = "No pudimos crear el rol. \(error.ruulUserMessage)"
        }
    }

    @ViewBuilder
    private func roleRow(_ role: RoleDefinition) -> some View {
        HStack(spacing: RuulSpacing.md) {
            ZStack {
                Circle()
                    .fill(role.system ? Color.ruulAccent.opacity(0.18) : Color.ruulSurface)
                    .frame(width: 36, height: 36)
                Image(systemName: role.system ? "crown.fill" : "person.fill")
                    .font(.footnote)
                    .foregroundStyle(role.system ? Color.ruulAccent : Color.ruulTextSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(role.humanLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(detail(for: role))
                    .font(.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
            if role.system {
                Text("SISTEMA")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(.vertical, RuulSpacing.xxs)
    }

    private func detail(for role: RoleDefinition) -> String {
        let permCount = role.permissions.count
        let permLabel: String
        switch permCount {
        case 0:  permLabel = "Sin permisos"
        case 1:  permLabel = "1 permiso"
        default: permLabel = "\(permCount) permisos"
        }
        if let max = role.maxHolders {
            return "\(permLabel) · máx. \(max)"
        }
        return permLabel
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { deletingRole != nil }, set: { if !$0 { deletingRole = nil } })
    }

    private func delete(_ role: RoleDefinition) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await app.groupsRepo.deleteGroupRole(groupId: groupId, roleId: role.id)
            deletingRole = nil
            await app.refreshProfileAndGroups()
        } catch {
            log.warning("delete_group_role failed: \(error.localizedDescription, privacy: .public)")
            self.error = "No pudimos eliminar el rol: \(error.localizedDescription)"
            deletingRole = nil
        }
    }

    /// Identifiable wrapper so `fullScreenCover(item:)` can drive both
    /// the create and edit cases. `role == nil` opens an empty editor.
    private struct EditingTarget: Identifiable {
        let role: RoleDefinition?
        var id: String { role?.id ?? "__new__" }
    }
}

/// Common role templates surfaced as 1-tap quick-create. El founder
/// puede después editar permisos individuales vía GroupRoleEditorSheet.
/// El roleId es estable (snake_case) y respeta la convención del
/// catálogo `groups.roles` jsonb.
private enum RolePreset: String, CaseIterable {
    case treasurer
    case host
    case moderator
    case observer

    var roleId: String { rawValue }

    var label: String {
        switch self {
        case .treasurer: return "Tesorero"
        case .host:      return "Anfitrión"
        case .moderator: return "Moderador"
        case .observer:  return "Observador"
        }
    }

    var icon: String {
        switch self {
        case .treasurer: return "banknote"
        case .host:      return "star.fill"
        case .moderator: return "shield.lefthalf.filled"
        case .observer:  return "eye"
        }
    }

    var summary: String {
        switch self {
        case .treasurer: return "Maneja el fondo: aporta, retira, audita, aprueba gastos."
        case .host:      return "Gestiona eventos: cierra, marca multas como pagadas."
        case .moderator: return "Modera el grupo: remover miembros, anular multas, cerrar apelaciones."
        case .observer:  return "Sólo lee y vota. Sin permisos de mutación."
        }
    }

    var permissions: [Permission] {
        switch self {
        case .treasurer:
            return [.fundContribute, .fundWithdraw, .fundAudit, .expenseApprove, .voidFine]
        case .host:
            return [.manageEvents, .markFinePaid]
        case .moderator:
            return [.removeMember, .voidFine, .closeAppeal, .castVote]
        case .observer:
            return [.castVote]
        }
    }
}
