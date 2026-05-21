import SwiftUI
import RuulUI
import RuulCore

/// "Roles del grupo" — assignment-focused view: who has which role.
/// Lists every active member grouped by their primary role (founder
/// pinned, then admin, then context roles, then plain member). Tap a
/// member → opens `MemberDetailView` where the admin can change role
/// assignments.
///
/// Separate from `GroupRolesSheet` (the *catalog* of role
/// definitions). This view answers "¿quién es admin?", the catalog
/// answers "¿qué permisos tiene el rol admin?".
@MainActor
public struct GroupRolesAssignmentsView: View {
    @State var coordinator: MembersCoordinator
    @Environment(AppState.self) private var app

    public init(coordinator: MembersCoordinator) {
        self._coordinator = State(initialValue: coordinator)
    }

    public var body: some View {
        AsyncContentView(
            phase: coordinator.activePhase,
            onRetry: { await coordinator.refresh() },
            empty: {
                ContentUnavailableView {
                    Label("Sin miembros", systemImage: "person.2")
                } description: {
                    Text("Comparte el código del grupo para invitar a tus amigos.")
                }
            },
            loaded: { rows in
                List {
                    ForEach(groupedRows(from: rows), id: \.role) { group in
                        Section {
                            ForEach(group.members, id: \.id) { row in
                                NavigationLink {
                                    MemberDetailView(
                                        memberWithProfile: row,
                                        group: coordinator.group,
                                        isCurrentUser: row.member.userId == coordinator.actorUserId,
                                        canManageRoles: coordinator.canManageRoles,
                                        founderCount: coordinator.founderCount,
                                        adminCount: coordinator.adminCount,
                                        onMemberChanged: { await coordinator.refresh() }
                                    )
                                } label: {
                                    memberRow(row)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(group.role.displayName)
                                    .font(.footnote.weight(.semibold))
                                Spacer()
                                Text("\(group.members.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Color.secondary)
                            }
                        } footer: {
                            if let footer = group.role.footer {
                                Text(footer)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        )
        .navigationTitle("Roles del grupo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.refresh() }
    }

    @ViewBuilder
    private func memberRow(_ row: MemberWithProfile) -> some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: row.displayName,
                imageURL: row.avatarURL,
                size: .small
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: RuulSpacing.xxs) {
                    Text(row.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    if row.member.userId == coordinator.actorUserId {
                        Text("· Tú")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                if row.member.roles.count > 1 {
                    Text(extraRolesLabel(for: row))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    /// "Admin · Anfitrión" when a member holds more than one role.
    /// The primary role drives the section grouping; the rest show as
    /// a subtitle so the user sees the full picture at a glance.
    private func extraRolesLabel(for row: MemberWithProfile) -> String {
        let primary = primaryRole(for: row)
        let extras = row.member.roles
            .filter { $0 != primary }
            .sorted { Self.priority($0) < Self.priority($1) }
            .map(\.displayName)
        return "También: " + extras.joined(separator: " · ")
    }

    // MARK: - Grouping

    private struct RoleGroup {
        let role: MemberRole
        let members: [MemberWithProfile]
    }

    private func groupedRows(from rows: [MemberWithProfile]) -> [RoleGroup] {
        var bucket: [MemberRole: [MemberWithProfile]] = [:]
        for row in rows {
            let primary = primaryRole(for: row)
            bucket[primary, default: []].append(row)
        }
        return bucket
            .map { RoleGroup(role: $0.key, members: $0.value.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) }
            .sorted { Self.priority($0.role) < Self.priority($1.role) }
    }

    private func primaryRole(for row: MemberWithProfile) -> MemberRole {
        // Pick the highest-priority role the member holds. Founders
        // first, then admin, then context roles, then plain member.
        row.member.roles.min(by: { Self.priority($0) < Self.priority($1) }) ?? .member
    }

    static func priority(_ role: MemberRole) -> Int {
        switch role {
        case .founder:   return 0
        case .admin:     return 1
        case .treasurer: return 2
        case .arbiter:   return 3
        case .host:      return 4
        case .observer:  return 5
        case .member:    return 6
        }
    }
}

private extension MemberRole {
    var displayName: String {
        switch self {
        case .founder:   return "Fundador"
        case .admin:     return "Administrador"
        case .treasurer: return "Tesorero"
        case .arbiter:   return "Mediador"
        case .host:      return "Anfitrión"
        case .observer:  return "Observador"
        case .member:    return "Miembro"
        }
    }

    var footer: String? {
        switch self {
        case .founder:   return "Identidad del grupo. No se transfiere."
        case .admin:     return "Capacidad operativa. Puede asignarse a varios miembros."
        case .host:      return "Rol contextual — anfitrión del próximo evento."
        default:         return nil
        }
    }
}
