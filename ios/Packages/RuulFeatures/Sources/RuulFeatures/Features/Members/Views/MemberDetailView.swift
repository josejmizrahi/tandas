import SwiftUI
import RuulUI
import RuulCore

/// Detail view de un miembro del grupo. Per DS v3 §6.4. V1 muestra solo
/// display data del MemberWithProfile + RuulCore.Group context — no fetch propio,
/// no stats. Cuando agreguemos MemberStatsCoordinator (Fase 2+), expander
/// con: events attended, fines history, RSVP rate.
public struct MemberDetailView: View {
    public let memberWithProfile: MemberWithProfile
    public let group: RuulCore.Group
    public let isCurrentUser: Bool

    public init(memberWithProfile: MemberWithProfile, group: RuulCore.Group, isCurrentUser: Bool) {
        self.memberWithProfile = memberWithProfile
        self.group = group
        self.isCurrentUser = isCurrentUser
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
            RuulListSectionHeader("ROLES EN ESTE GRUPO")
            RuulSeparatedRows(items: rolesList.map(RoleRow.init)) { entry in
                infoRow(icon: roleIcon(entry.role), label: roleLabel(entry.role))
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

    /// Roles a renderizar. Usamos `member.roles` (canonical multi-role array
    /// post-migration 00019). Si por algún motivo viene vacío, fallback a
    /// `[member]` para que la sección nunca se vea hueca.
    private var rolesList: [MemberRole] {
        let raw = memberWithProfile.member.roles
        return raw.isEmpty ? [.member] : raw
    }

    private func roleLabel(_ role: MemberRole) -> String {
        switch role {
        case .founder:   return "Fundador"
        case .member:    return "Miembro"
        case .host:      return "Anfitrión"
        case .treasurer: return "Tesorero"
        case .arbiter:   return "Árbitro"
        case .observer:  return "Observador"
        }
    }

    private func roleIcon(_ role: MemberRole) -> String {
        switch role {
        case .founder:   return "crown.fill"
        case .member:    return "person.fill"
        case .host:      return "star.fill"
        case .treasurer: return "banknote"
        case .arbiter:   return "scale.3d"
        case .observer:  return "eye"
        }
    }

    private var joinedFormatted: String {
        "Se unió el \(memberWithProfile.member.joinedAt.ruulLongDate)"
    }

    /// Identifiable wrapper so `MemberRole` (enum, not Identifiable) can
    /// feed `RuulSeparatedRows` without polluting the public type.
    private struct RoleRow: Identifiable {
        let role: MemberRole
        var id: MemberRole { role }
    }
}

#if DEBUG
#Preview("MemberDetailView") {
    Text("MemberDetailView preview requires Member + Profile + RuulCore.Group fixtures — see Showcase.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
