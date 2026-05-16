import SwiftUI
import RuulUI
import RuulCore

/// Detail view de un miembro del grupo. Per DS v3 §6.4. V1 muestra solo
/// display data del MemberWithProfile + RuulCore.Group context — no fetch propio,
/// no stats. Cuando agreguemos MemberStatsCoordinator (Fase 2+), expander
/// con: events attended, fines history, RSVP rate.
public struct MemberDetailView: View {
    @Environment(AppState.self) private var app
    public let memberWithProfile: MemberWithProfile
    public let group: RuulCore.Group
    public let isCurrentUser: Bool
    /// Whether the calling user can manage roles on this member. Wired
    /// from the parent coordinator (which has the actor's permissions).
    /// `false` hides the "Editar roles" CTA — server is still the
    /// authoritative gate via `assign_role`/`unassign_role` RPCs.
    public let canManageRoles: Bool
    /// Active-founder count in this group, surfaced by the parent so the
    /// `MemberRolesPicker` can disable the founder toggle on the last
    /// holder. Defaults to 1 (conservative) when the parent doesn't
    /// supply it.
    public let founderCount: Int

    @State private var showRolesPicker: Bool = false

    public init(
        memberWithProfile: MemberWithProfile,
        group: RuulCore.Group,
        isCurrentUser: Bool,
        canManageRoles: Bool = false,
        founderCount: Int = 1
    ) {
        self.memberWithProfile = memberWithProfile
        self.group = group
        self.isCurrentUser = isCurrentUser
        self.canManageRoles = canManageRoles
        self.founderCount = founderCount
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                hero
                rolesSection
                joinedSection
                if isCurrentUser {
                    youHintSection
                }
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .ruulAmbientScreen(palette: nil)
        .navigationTitle("Miembro")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showRolesPicker) {
            MemberRolesPicker(
                group: group,
                target: memberWithProfile,
                founderCount: founderCount
            )
            .environment(app)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .center, spacing: RuulSpacing.md) {
            RuulAvatar(
                name: displayName,
                imageURL: avatarURL,
                size: .hero
            )
            VStack(spacing: RuulSpacing.xxs) {
                Text(displayName)
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .multilineTextAlignment(.center)
                Text(group.name)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, RuulSpacing.lg)
    }

    // MARK: - Roles

    private var rolesSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack {
                RuulListSectionHeader("ROLES EN ESTE GRUPO")
                Spacer()
                if canManageRoles {
                    Button("Editar") { showRolesPicker = true }
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            RuulSeparatedRows(items: rolesList) { entry in
                infoRow(icon: roleIcon(for: entry.id), label: entry.humanLabel)
            }
        }
    }

    // MARK: - Joined date

    private var joinedSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            RuulListSectionHeader("UNIÓN")
            infoRow(icon: "calendar", label: joinedFormatted)
        }
    }

    private var youHintSection: some View {
        Text("Este eres tú.")
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, RuulSpacing.md)
    }

    @ViewBuilder
    private func infoRow(icon: String, label: String) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: icon)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
                .frame(width: RuulSpacing.xxl, alignment: .center)
                .accessibilityHidden(true)
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, RuulSpacing.sm)
    }

    // MARK: - Derived

    private var displayName: String {
        memberWithProfile.displayName
    }

    private var avatarURL: URL? {
        memberWithProfile.avatarURL
    }

    /// Roles to render, resolved against the group's role catalog.
    /// Custom roles (`seat_owner`, `treasurer`, …) carried in
    /// `rawRoles` are rendered with their catalog label; unknown role
    /// ids fall back to a humanised version of the id so we never
    /// leak raw jsonb keys to users.
    private var rolesList: [RoleDefinition] {
        let raw = memberWithProfile.member.rawRoles
        let safe = raw.isEmpty ? ["member"] : raw
        let catalog = group.effectiveRoles
        return safe.map { id in
            catalog[id] ?? RoleDefinition(id: id, label: nil, permissions: [], system: false)
        }
    }

    private func roleIcon(for roleId: String) -> String {
        switch roleId {
        case "founder":   return "crown.fill"
        case "member":    return "person.fill"
        case "host":      return "star.fill"
        case "treasurer": return "banknote"
        case "arbiter":   return "scale.3d"
        case "observer":  return "eye"
        default:          return "person.badge.shield.checkmark"
        }
    }

    private var joinedFormatted: String {
        "Se unió el \(memberWithProfile.member.joinedAt.ruulLongDate)"
    }
}

#if DEBUG
#Preview("MemberDetailView") {
    Text("MemberDetailView preview requires Member + Profile + RuulCore.Group fixtures — see Showcase.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
