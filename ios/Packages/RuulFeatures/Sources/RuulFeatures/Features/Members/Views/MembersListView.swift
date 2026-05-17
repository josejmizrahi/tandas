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
            Color.ruulBackground.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.members.isEmpty {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(RuulSpacing.lg)
                } else if coordinator.isLoading && coordinator.members.isEmpty {
                    RuulLoadingState()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(coordinator.activeMembers) { row in
                                NavigationLink {
                                    MemberDetailView(
                                        memberWithProfile: row,
                                        group: coordinator.group,
                                        isCurrentUser: row.member.userId == coordinator.actorUserId,
                                        canManageRoles: coordinator.canManageRoles,
                                        founderCount: coordinator.founderCount
                                    )
                                } label: {
                                    memberRow(row)
                                }
                                .buttonStyle(.plain)
                                if row.id != coordinator.activeMembers.last?.id {
                                    Divider().background(Color.ruulSeparator).padding(.leading, 76)
                                }
                            }
                        }
                        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                        .padding(RuulSpacing.lg)
                    }
                    .refreshable { await coordinator.refresh() }
                }
            }
        }
        .navigationTitle("Miembros (\(coordinator.activeMembers.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                RuulCloseToolbarButton { dismiss() }
            }
        }
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
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    if row.member.userId == coordinator.actorUserId {
                        Text("· Tú")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                }
                Text(subtitleFor(row))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer()
            if row.member.isFounder {
                Text("FUNDADOR")
                    .ruulTextStyle(RuulTypography.captionBold)
                    .foregroundStyle(Color.ruulAccent)
            }
            Image(systemName: "chevron.right")
                .ruulTextStyle(RuulTypography.captionBold)
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityHidden(true)
        }
        .padding(RuulSpacing.md)
        .contentShape(Rectangle())
    }

    private func subtitleFor(_ row: MemberWithProfile) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: app.profile?.locale ?? "es-MX")
        return "Se unió \(formatter.localizedString(for: row.member.joinedAt, relativeTo: .now))"
    }
}
