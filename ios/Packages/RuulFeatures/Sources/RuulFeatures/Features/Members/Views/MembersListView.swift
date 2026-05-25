import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct MembersListView: View {
    @State var coordinator: MembersCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: MembersCoordinator) {
        self._coordinator = State(initialValue: coordinator)
    }

    public var body: some View {
        ZStack {
            Color.ruulBackgroundRecessed.ignoresSafeArea()
            AsyncContentView(
                phase: coordinator.activePhase,
                onRetry: { await coordinator.refresh() },
                empty: {
                    ContentUnavailableView {
                        Label("Solo estás tú", systemImage: "person.2")
                    } description: {
                        Text("Comparte el código del grupo para invitar a tus amigos.")
                    }
                    .padding(RuulSpacing.lg)
                },
                loaded: { rows in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
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
                                if row.id != rows.last?.id {
                                    Divider().background(Color(.separator)).padding(.leading, 76)
                                }
                            }
                        }
                        .ruulCardSurface(.solid)
                        .padding(RuulSpacing.lg)
                    }
                    .refreshable { await coordinator.refresh() }
                }
            )
        }
        .ruulSheetToolbar("Miembros (\(coordinator.activeMembers.count))")
        .task { await coordinator.refresh() }
    }

    @ViewBuilder
    private func memberRow(_ row: MemberWithProfile) -> some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: row.displayName,
                imageURL: row.avatarURL,
                size: .medium
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
                Text(subtitleFor(row))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            if row.member.joinedVia == "placeholder" {
                Text("Pendiente")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, RuulSpacing.xs)
                    .padding(.vertical, 2)
                    .background(
                        Color.ruulSurface.opacity(0.6),
                        in: Capsule()
                    )
                    .accessibilityLabel("Miembro pendiente de activación")
            } else if row.member.isFounder {
                Text("Fundador")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ruulAccent)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .padding(RuulSpacing.md)
        .contentShape(Rectangle())
    }

    private func subtitleFor(_ row: MemberWithProfile) -> String {
        if row.member.joinedVia == "placeholder" {
            return "Agregado por admin · sin activar"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return "Se unió \(formatter.localizedString(for: row.member.joinedAt, relativeTo: .now))"
    }
}
