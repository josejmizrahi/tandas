import SwiftUI
import RuulUI
import RuulCore

/// Detail view de un miembro del grupo. Per DS v3 §6.4. Hidrata stats
/// (asistencia, multas, votos) vía `get_member_summary` RPC (mig 00254)
/// expuesto en `GroupSummaryRepository.memberSummary`.
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
    /// Active-founder count in this group. Post-mig 00262: founder es
    /// identity inmutable; el picker filtra el founder toggle, así que
    /// este field sirve solo para mostrar el badge "crown" si aplica.
    public let founderCount: Int
    /// Active-admin count. Post-mig 00262: el picker lockea el admin
    /// toggle cuando es el último admin (server lo rechazaría también).
    /// Defaults a 1 (conservative) when parent doesn't supply.
    public let adminCount: Int
    /// Async callback fired when the role picker mutates rawRoles. The
    /// parent (typically `MembersCoordinator`) should refresh its
    /// `members` list so MembersAdmin/List views see the new roles.
    /// `nil` skips the upward refresh; the local section still updates
    /// via `liveRawRoles`.
    public var onMemberChanged: (() async -> Void)?

    @State private var showRolesPicker: Bool = false
    @State private var summary: MemberSummary?
    @State private var summaryLoading: Bool = false
    /// Live mirror of the member's rawRoles. Seeded from the value-passed
    /// `memberWithProfile` at init; updated optimistically when the role
    /// picker completes so the "ROLES EN ESTE GRUPO" section reflects
    /// the new state without waiting for a parent refetch.
    @State private var liveRawRoles: [String]

    public init(
        memberWithProfile: MemberWithProfile,
        group: RuulCore.Group,
        isCurrentUser: Bool,
        canManageRoles: Bool = false,
        founderCount: Int = 1,
        adminCount: Int = 1,
        onMemberChanged: (() async -> Void)? = nil
    ) {
        self.memberWithProfile = memberWithProfile
        self.group = group
        self.isCurrentUser = isCurrentUser
        self.canManageRoles = canManageRoles
        self.founderCount = founderCount
        self.adminCount = adminCount
        self.onMemberChanged = onMemberChanged
        _liveRawRoles = State(initialValue: memberWithProfile.member.rawRoles)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                hero
                statsSection
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
                founderCount: founderCount,
                adminCount: adminCount,
                onChange: { updated in
                    // Reflect locally so the rolesSection updates
                    // immediately, then bubble up so MembersAdmin/List
                    // get fresh data when the picker closes.
                    liveRawRoles = updated.rawRoles
                    if let onMemberChanged { await onMemberChanged() }
                }
            )
            .environment(app)
        }
        .task { await loadSummary() }
    }

    /// Carga stats via get_member_summary RPC. La sección se renderiza
    /// con placeholders ("—") mientras `summary == nil`, y se rellena
    /// cuando la llamada vuelve. Best-effort: cualquier error deja la
    /// section vacía sin bloquear el resto del detail.
    private func loadSummary() async {
        guard !summaryLoading, summary == nil else { return }
        guard let repo = app.groupSummaryRepo else { return }
        summaryLoading = true
        defer { Task { @MainActor in summaryLoading = false } }
        let userId = memberWithProfile.member.userId
        if let s = try? await repo.memberSummary(groupId: group.id, userId: userId) {
            await MainActor.run { summary = s }
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
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                Text(group.name)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, RuulSpacing.lg)
    }

    // MARK: - Stats (asistencia / multas / votos)

    /// 4 tiles: Asistencia % · Multas pendientes (cents) · Multas pagadas
    /// (count) · Votos emitidos. Se renderiza con placeholders ("—")
    /// hasta que la RPC vuelve. Si la persona no es miembro activo
    /// (is_member=false), la section no se muestra.
    @ViewBuilder
    private var statsSection: some View {
        if summary?.isMember != false {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                RuulListSectionHeader("ACTIVIDAD")
                HStack(spacing: RuulSpacing.sm) {
                    statTile(value: attendanceDisplay, label: "Asistencia")
                    statTile(value: pendingFinesDisplay, label: "Por pagar")
                    statTile(value: paidFinesDisplay, label: "Pagadas")
                    statTile(value: votesDisplay, label: "Votos")
                }
            }
        }
    }

    private var attendanceDisplay: String {
        guard let summary else { return "—" }
        if let rate = summary.attendanceRate {
            return "\(Int(round(rate * 100)))%"
        }
        if summary.eventsEligible == 0 { return "—" }
        return "\(summary.eventsAttended)/\(summary.eventsEligible)"
    }

    private var pendingFinesDisplay: String {
        guard let summary else { return "—" }
        if summary.finesPendingCount == 0 { return "$0" }
        return formatCents(summary.finesPendingAmountCents)
    }

    private var paidFinesDisplay: String {
        guard let summary else { return "—" }
        return "\(summary.finesPaidCount)"
    }

    private var votesDisplay: String {
        guard let summary else { return "—" }
        return "\(summary.votesCast)"
    }

    private func formatCents(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text(value)
                .font(.body.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.sm)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    // MARK: - Roles

    private var rolesSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack {
                RuulListSectionHeader("ROLES EN ESTE GRUPO")
                Spacer()
                if canManageRoles {
                    Button("Editar") { showRolesPicker = true }
                        .font(.caption.weight(.bold))
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
            .font(.caption)
            .foregroundStyle(Color(.tertiaryLabel))
            .frame(maxWidth: .infinity)
            .padding(.top, RuulSpacing.md)
    }

    @ViewBuilder
    private func infoRow(icon: String, label: String) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .frame(width: RuulSpacing.xxl, alignment: .center)
                .accessibilityHidden(true)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
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
        let safe = liveRawRoles.isEmpty ? ["member"] : liveRawRoles
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
