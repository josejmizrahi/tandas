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
        .background(Color.ruulBackground.ignoresSafeArea())
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
            Text("ROLES EN ESTE GRUPO")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextSecondary)
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                ForEach(rolesList, id: \.self) { role in
                    HStack(spacing: RuulSpacing.sm) {
                        Image(systemName: roleIcon(role))
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulAccent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(roleLabel(role))
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                    }
                }
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .strokeBorder(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Joined date

    private var joinedSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("UNIÓN")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextSecondary)
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "calendar")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulInfo)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(joinedFormatted)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .strokeBorder(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private var youHintSection: some View {
        Text("Este eres tú.")
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, RuulSpacing.md)
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
}

#if DEBUG
#Preview("MemberDetailView") {
    Text("MemberDetailView preview requires Member + Profile + RuulCore.Group fixtures — see Showcase.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
