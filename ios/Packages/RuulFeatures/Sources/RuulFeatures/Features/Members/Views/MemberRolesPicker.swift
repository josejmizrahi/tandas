import SwiftUI
import OSLog
import RuulUI
import RuulCore

/// Sheet that lets an authorised actor assign or unassign roles on a
/// single member. The catalog comes from `group.effectiveRoles`; the
/// member's current rawRoles drive the initial toggle state. Each
/// toggle change emits an `assign_role` or `unassign_role` RPC
/// immediately — no draft state, no commit button — so the activity
/// feed records each grant/revoke as a discrete atom.
///
/// Toggle pattern: optimistic. `roles` @State is updated synchronously
/// inside the Binding.set so SwiftUI sees the new value on the same
/// render cycle (otherwise the Toggle reverts visually because the
/// async RPC hasn't completed yet). On RPC failure we roll back and
/// surface the error at the top of the sheet.
///
/// Gating: only presented when the calling user has `assignRoles`. The
/// `member` system role and the last `founder` toggle are disabled
/// in-UI; server enforces the same rules as the authoritative gate.
@MainActor
public struct MemberRolesPicker: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let group: RuulCore.Group
    public let target: MemberWithProfile
    /// Total count of active founders in the group (driven by the parent
    /// coordinator). Used to disable the "founder" toggle when the
    /// target is the last one — server would reject, but we hide the
    /// affordance for clarity.
    public let founderCount: Int
    public var onChange: (() async -> Void)?

    @State private var roles: [String]
    @State private var inFlight: Set<String> = []
    @State private var error: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "roles.picker")

    public init(
        group: RuulCore.Group,
        target: MemberWithProfile,
        founderCount: Int,
        onChange: (() async -> Void)? = nil
    ) {
        self.group = group
        self.target = target
        self.founderCount = founderCount
        self.onChange = onChange
        _roles = State(initialValue: target.member.rawRoles)
    }

    private var catalog: [RoleDefinition] {
        group.effectiveRoles.values.sorted { lhs, rhs in
            if lhs.system != rhs.system { return lhs.system }
            if lhs.id == "founder" { return true }
            if rhs.id == "founder" { return false }
            if lhs.id == "member"  { return true }
            if rhs.id == "member"  { return false }
            return lhs.humanLabel.localizedStandardCompare(rhs.humanLabel) == .orderedAscending
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.ruulNegative)
                            .ruulTextStyle(RuulTypography.caption)
                    }
                }
                Section {
                    headerRow
                }
                Section("Roles disponibles") {
                    ForEach(catalog, id: \.id) { role in
                        roleToggle(role)
                    }
                }
            }
            .navigationTitle("Roles del miembro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    RuulCloseToolbarButton { dismiss() }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(name: target.displayName, imageURL: target.avatarURL, size: .medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text("Cambia un toggle para asignar o retirar el rol al instante.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, RuulSpacing.xxs)
    }

    @ViewBuilder
    private func roleToggle(_ role: RoleDefinition) -> some View {
        let isOn = roles.contains(role.id)
        let locked = isLocked(role, isOn: isOn)
        // Binding.get reads live state on every query so the optimistic
        // update in set() is reflected immediately. Capturing `isOn` in
        // a `let` would make the Toggle visually snap back to its old
        // value until the async RPC finished.
        let bound = Binding<Bool>(
            get: { roles.contains(role.id) },
            set: { newOn in
                guard !locked,
                      !inFlight.contains(role.id),
                      newOn != roles.contains(role.id)
                else { return }
                // Optimistic: mutate local state synchronously so the
                // Toggle stays in the new visual position while the RPC
                // is in flight. Rollback happens in `toggle` on error.
                if newOn {
                    roles.append(role.id)
                } else {
                    roles.removeAll { $0 == role.id }
                }
                Task { await toggle(role: role.id, on: newOn) }
            }
        )
        HStack {
            Toggle(isOn: bound) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.humanLabel)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(lockReason(role: role, isOn: isOn) ?? permissionsSummary(for: role))
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            .disabled(locked || inFlight.contains(role.id))
            if inFlight.contains(role.id) {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Locking + reasons

    private func isLocked(_ role: RoleDefinition, isOn: Bool) -> Bool {
        if role.id == "member" { return true }
        if role.id == "founder", isOn, founderCount <= 1 { return true }
        return false
    }

    private func lockReason(role: RoleDefinition, isOn: Bool) -> String? {
        if role.id == "member" {
            return "Rol base — siempre presente."
        }
        if role.id == "founder", isOn, founderCount <= 1 {
            return "Asigna fundador a otro miembro antes de retirar este."
        }
        return nil
    }

    private func permissionsSummary(for role: RoleDefinition) -> String {
        switch role.permissions.count {
        case 0:  return "Sin permisos."
        case 1:  return "1 permiso · \(role.permissions[0].humanLabel)."
        case let n where n <= 3:
            return role.permissions.map(\.humanLabel).joined(separator: ", ") + "."
        default:
            let preview = role.permissions.prefix(2).map(\.humanLabel).joined(separator: ", ")
            return "\(preview) y \(role.permissions.count - 2) más."
        }
    }

    // MARK: - Toggle

    private func toggle(role: String, on: Bool) async {
        guard !inFlight.contains(role) else { return }
        inFlight.insert(role)
        defer { inFlight.remove(role) }
        do {
            let updated: Member
            if on {
                updated = try await app.groupsRepo.assignRole(
                    groupId: group.id,
                    userId: target.member.userId,
                    role: role
                )
            } else {
                updated = try await app.groupsRepo.unassignRole(
                    groupId: group.id,
                    userId: target.member.userId,
                    role: role
                )
            }
            // Server is the source of truth; align with whatever it
            // returned (e.g. idempotent no-op still gives us the
            // canonical rawRoles).
            roles = updated.rawRoles
            error = nil
            if let onChange { await onChange() }
        } catch {
            // Rollback the optimistic mutation so the toggle reverts.
            if on {
                roles.removeAll { $0 == role }
            } else if !roles.contains(role) {
                roles.append(role)
            }
            log.warning("toggle role \(role, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.error = "No pudimos actualizar el rol: \(error.localizedDescription)"
        }
    }
}
