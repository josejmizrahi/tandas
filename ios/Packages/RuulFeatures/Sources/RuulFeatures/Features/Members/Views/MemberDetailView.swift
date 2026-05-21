import SwiftUI
import RuulUI
import RuulCore

/// Detail view de una persona inside this group context.
///
/// Per Ruul Identity & Context Doctrine (2026-05-20): a person doesn't
/// have multiple profiles — they have one identity expressed through
/// different contexts. This surface frames the viewed person as
/// "[Nombre] en [GroupContext]": Layer 1 (persistent identity) sits
/// compactly at the top; Layer 2 (contextual participation) is the
/// primary content below.
///
/// Sections (in this order, doctrine §5 + §7):
///   - Identity header (compact: avatar + name + "(Tú)" badge if owner)
///   - Trust signals row (subtle chips derived from MemberSummary,
///     max 3 — "Al día", "Activo en eventos", "Vota seguido")
///   - "Aquí" participation card (narrative sentences from
///     MemberSummary — never stat-dashboard tiles)
///   - "Responsabilidades" card (sentence-form role rendering;
///     hidden when only the default `member` role applies)
///   - Joined footer (single soft line)
///
/// Banned (per doctrine §11): role matrices, ACL grids, permission
/// dashboards, reputation scores. Role editing lives in a toolbar
/// menu (admin only), never inline in the main view.
public struct MemberDetailView: View {
    @Environment(AppState.self) private var app
    public let memberWithProfile: MemberWithProfile
    public let group: RuulCore.Group
    public let isCurrentUser: Bool
    /// Whether the calling user can manage roles on this member. Wired
    /// from the parent coordinator (which has the actor's permissions).
    /// `false` hides the toolbar edit menu — server is still the
    /// authoritative gate via `assign_role`/`unassign_role` RPCs.
    public let canManageRoles: Bool
    /// Active-founder count in this group. Post-mig 00262: founder es
    /// identity inmutable; el picker filtra el founder toggle.
    public let founderCount: Int
    /// Active-admin count. Post-mig 00262: el picker lockea el admin
    /// toggle cuando es el último admin (server lo rechazaría también).
    public let adminCount: Int
    /// Async callback fired when the role picker mutates rawRoles. Parent
    /// (typically `MembersCoordinator`) should refresh its `members`
    /// list so MembersAdmin/List views see the new responsibilities.
    public var onMemberChanged: (() async -> Void)?

    @State private var showRolesPicker: Bool = false
    @State private var summary: MemberSummary?
    @State private var summaryLoading: Bool = false
    /// Live mirror of the member's rawRoles. Seeded from the value-passed
    /// `memberWithProfile` at init; updated optimistically when the role
    /// picker completes so the responsibilities section reflects the
    /// new state without waiting for a parent refetch.
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
                identityHeader
                if !trustChips.isEmpty {
                    trustChipsRow
                }
                participationCard
                responsibilitiesCard
                joinedFooter
            }
            .padding(.horizontal, RuulSpacing.screenPadding)
            .padding(.top, RuulSpacing.md)
            .padding(.bottom, RuulSpacing.tabBarBottomSafeArea)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManageRoles {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showRolesPicker = true
                        } label: {
                            Label("Editar responsabilidades", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showRolesPicker) {
            MemberRolesPicker(
                group: group,
                target: memberWithProfile,
                founderCount: founderCount,
                adminCount: adminCount,
                onChange: { updated in
                    // Reflect locally so responsibilities update
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

    /// Carga stats via get_member_summary RPC. Best-effort: cualquier
    /// error deja las secciones colapsadas sin bloquear el resto del
    /// detail (trust chips + participation card se ocultan cuando no
    /// hay summary).
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

    // MARK: - Layer 1: Identity header (compact)

    /// Compact identity strip per Identity & Context Doctrine §7. Avatar
    /// + name + optional "(Tú)" tag. The group context lives implicitly
    /// in the navigation title bar above; this view is always opened
    /// "[Nombre] en [GroupContext]" from a group surface.
    private var identityHeader: some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: displayName,
                imageURL: avatarURL,
                size: .large
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: RuulSpacing.xs) {
                    Text(displayName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if isCurrentUser {
                        Text("(Tú)")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Text("En \(group.name)")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Layer 2: Trust signals (subtle)

    /// Tiny capsule chips, max 3, derived from `MemberSummary`. Doctrine
    /// §5 Trust Signals: subtle only, never reputation scores or
    /// gamification. Hidden entirely when no chips qualify.
    private var trustChipsRow: some View {
        HStack(spacing: RuulSpacing.xs) {
            ForEach(trustChips, id: \.self) { chip in
                trustChip(chip)
            }
            Spacer(minLength: 0)
        }
    }

    private func trustChip(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, RuulSpacing.sm)
            .padding(.vertical, RuulSpacing.xxs)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
    }

    /// Derive up to 3 trust signals from the `MemberSummary`. Calm,
    /// matter-of-fact phrases — never "score N points" or "level X".
    private var trustChips: [String] {
        guard let summary, summary.isMember else { return [] }
        var chips: [String] = []

        // 1. Pago: cumplió con multas (al día) o nunca tuvo (sin multas)
        if summary.finesPendingCount == 0 {
            if summary.finesPaidCount > 0 {
                chips.append("Al día con pagos")
            } else if summary.eventsEligible >= 3 {
                // "Sin multas" solo es señal si llevan tiempo en el grupo
                chips.append("Sin multas")
            }
        }

        // 2. Asistencia: ≥75% en al menos 3 eventos elegibles
        if let rate = summary.attendanceRate, rate >= 0.75, summary.eventsAttended >= 3 {
            chips.append("Activo en eventos")
        }

        // 3. Participación en decisiones
        if summary.votesCast >= 3 {
            chips.append("Vota seguido")
        }

        return Array(chips.prefix(3))
    }

    // MARK: - Layer 2: "Aquí" participation card

    /// Participation narrative — what this person does inside this
    /// group. Replaces the previous 4-tile stat dashboard with
    /// readable sentences (doctrine §11: "exposed as plain language
    /// sentences"). One row per non-trivial fact.
    @ViewBuilder
    private var participationCard: some View {
        let lines = participationLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                sectionHeader("Aquí")
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        if idx > 0 { rowDivider }
                        participationRow(symbol: line.symbol, text: line.text)
                    }
                }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
            }
        }
    }

    private struct ParticipationLine {
        let symbol: String
        let text: String
    }

    private var participationLines: [ParticipationLine] {
        guard let summary, summary.isMember else { return [] }
        var lines: [ParticipationLine] = []

        // Eventos
        if summary.eventsEligible > 0 {
            let text: String
            if summary.eventsAttended == summary.eventsEligible {
                text = "Fue a los \(summary.eventsAttended) eventos donde se le esperaba"
            } else {
                text = "Fue a \(summary.eventsAttended) de \(summary.eventsEligible) eventos"
            }
            lines.append(.init(symbol: "calendar", text: text))
        }

        // Multas pendientes — destacar solo si las hay
        if summary.finesPendingCount > 0 {
            let amount = formatCents(summary.finesPendingAmountCents)
            let n = summary.finesPendingCount
            let text = n == 1
                ? "Debe \(amount) por una multa"
                : "Debe \(amount) por \(n) multas"
            lines.append(.init(symbol: "creditcard", text: text))
        } else if summary.finesPaidCount > 0 {
            let amount = formatCents(summary.finesPaidAmountCents)
            let n = summary.finesPaidCount
            let text = n == 1
                ? "Pagó \(amount) en una multa"
                : "Pagó \(amount) en \(n) multas"
            lines.append(.init(symbol: "checkmark.seal", text: text))
        }

        // Votos
        if summary.votesCast > 0 {
            let text = summary.votesCast == 1
                ? "Participó en una decisión"
                : "Participó en \(summary.votesCast) decisiones"
            lines.append(.init(symbol: "hand.raised", text: text))
        }

        return lines
    }

    private func participationRow(symbol: String, text: String) -> some View {
        HStack(spacing: RuulSpacing.md) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .frame(width: RuulSpacing.xxl, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
    }

    // MARK: - Layer 2: Responsibilities card

    /// Responsibilities (specialized roles only). Doctrine §11: never
    /// expose role matrices or permission grids. The default `member`
    /// role is filtered — everyone is a member, so it adds noise.
    /// Custom roles fall back to the catalog's `humanLabel` so the user
    /// reads "Tesorero" / "Anfitrión", not the snake_case id.
    @ViewBuilder
    private var responsibilitiesCard: some View {
        let entries = specialResponsibilities
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                sectionHeader("Responsabilidades")
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                        if idx > 0 { rowDivider }
                        participationRow(
                            symbol: roleIcon(for: entry.id),
                            text: responsibilitySentence(for: entry)
                        )
                    }
                }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
            }
        }
    }

    /// Roles to render, with the universal `member` removed (everyone
    /// is a member by definition; surfacing it adds noise).
    private var specialResponsibilities: [RoleDefinition] {
        let nonMember = liveRawRoles.filter { $0 != "member" }
        guard !nonMember.isEmpty else { return [] }
        let catalog = group.effectiveRoles
        return nonMember.map { id in
            catalog[id] ?? RoleDefinition(id: id, label: nil, permissions: [], system: false)
        }
    }

    /// Canonical Spanish phrase for each system role; falls back to the
    /// custom role's `humanLabel` for catalog-defined roles.
    private func responsibilitySentence(for role: RoleDefinition) -> String {
        switch role.id {
        case "founder":   return "Arrancó este grupo"
        case "admin":     return "Coordina decisiones"
        case "host":      return "Organiza eventos"
        case "treasurer": return "Lleva el dinero del fondo"
        case "arbiter":   return "Resuelve apelaciones"
        case "observer":  return "Observa decisiones"
        default:          return role.humanLabel
        }
    }

    // MARK: - Joined footer

    private var joinedFooter: some View {
        Text(joinedFormatted)
            .font(.caption)
            .foregroundStyle(Color(.tertiaryLabel))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, RuulSpacing.md)
    }

    // MARK: - Section helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(.tertiaryLabel))
            .padding(.leading, RuulSpacing.xxs)
    }

    private var rowDivider: some View {
        Divider()
            .background(Color(.separator))
            .padding(.leading, RuulSpacing.xxl + RuulSpacing.md + RuulSpacing.md)
    }

    // MARK: - Derived

    private var displayName: String {
        memberWithProfile.displayName
    }

    private var avatarURL: URL? {
        memberWithProfile.avatarURL
    }

    private func roleIcon(for roleId: String) -> String {
        switch roleId {
        case "founder":   return "crown.fill"
        case "admin":     return "person.crop.circle.badge.checkmark"
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

    private func formatCents(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}

#if DEBUG
#Preview("MemberDetailView") {
    Text("MemberDetailView preview requires Member + Profile + RuulCore.Group fixtures — see Showcase.")
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
}
#endif
