import SwiftUI
import RuulUI
import RuulCore

/// Nivel 1 home — the group as a persistent social domain.
///
/// Layout (Apple Settings pattern, post-refactor 2026-05-17):
///   Hero (avatar + name + member count, slim)
///   RESUMEN (4 stat tiles)
///   IDENTIDAD (nombre/foto + invite code share)
///   PERSONAS (miembros + invitar + roles personalizados)
///   REGLAS Y MÓDULOS (módulos activos + reglas del grupo + presets)
///   DINERO Y ZONA (moneda + timezone)
///   PENDIENTES (votos abiertos + acciones, solo si hay 1+)
///   AVANZADO (rotar código + archivar + salir, destructives)
///
/// Antes había una sección CONFIGURACIÓN monolítica con 7 items
/// mezclados (identidad, moneda, timezone, módulos, reglas, presets,
/// roles) + COMUNIDAD con miembros+invitar+votos+actions dispares.
/// El usuario perdía cosas porque el orden no reflejaba ningún
/// modelo mental coherente.
@MainActor
public struct GroupHomeView: View {
    @State var coordinator: GroupHomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public var onOpenMembersList: (() -> Void)?
    public var onOpenMembersAdmin: (() -> Void)?
    public let onOpenGovernance: () -> Void
    public let onOpenRulePresets: () -> Void
    public let onLeaveGroup: () -> Void
    public let onShareInvite: () -> Void

    public var onEditIdentity: (() -> Void)?
    public var onPickModules: (() -> Void)?
    public var onPickCurrency: (() -> Void)?
    public var onPickTimezone: (() -> Void)?
    public var onRotateCode: (() -> Void)?
    public var onInviteMembers: (() -> Void)?
    public var onConfirmLeave: (() -> Void)?
    public var onOpenRoles: (() -> Void)?
    public var onArchiveGroup: (() -> Void)?

    // Pass 2 — dashboard callbacks
    public var onOpenMyLedger: (() -> Void)?
    public var onOpenMyFines: (() -> Void)?
    public var onOpenVotes: (() -> Void)?
    public var onOpenInbox: (() -> Void)?

    public init(
        coordinator: GroupHomeCoordinator,
        onOpenMembersList: (() -> Void)? = nil,
        onOpenMembersAdmin: (() -> Void)? = nil,
        onOpenGovernance: @escaping () -> Void,
        onOpenRulePresets: @escaping () -> Void,
        onLeaveGroup: @escaping () -> Void,
        onShareInvite: @escaping () -> Void,
        onEditIdentity: (() -> Void)? = nil,
        onPickModules: (() -> Void)? = nil,
        onPickCurrency: (() -> Void)? = nil,
        onPickTimezone: (() -> Void)? = nil,
        onRotateCode: (() -> Void)? = nil,
        onInviteMembers: (() -> Void)? = nil,
        onConfirmLeave: (() -> Void)? = nil,
        onOpenRoles: (() -> Void)? = nil,
        onArchiveGroup: (() -> Void)? = nil,
        onOpenMyLedger: (() -> Void)? = nil,
        onOpenMyFines: (() -> Void)? = nil,
        onOpenVotes: (() -> Void)? = nil,
        onOpenInbox: (() -> Void)? = nil
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onOpenMembersList = onOpenMembersList
        self.onOpenMembersAdmin = onOpenMembersAdmin
        self.onOpenGovernance = onOpenGovernance
        self.onOpenRulePresets = onOpenRulePresets
        self.onLeaveGroup = onLeaveGroup
        self.onShareInvite = onShareInvite
        self.onEditIdentity = onEditIdentity
        self.onPickModules = onPickModules
        self.onPickCurrency = onPickCurrency
        self.onPickTimezone = onPickTimezone
        self.onRotateCode = onRotateCode
        self.onInviteMembers = onInviteMembers
        self.onConfirmLeave = onConfirmLeave
        self.onOpenRoles = onOpenRoles
        self.onArchiveGroup = onArchiveGroup
        self.onOpenMyLedger = onOpenMyLedger
        self.onOpenMyFines = onOpenMyFines
        self.onOpenVotes = onOpenVotes
        self.onOpenInbox = onOpenInbox
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            SwiftUI.Group {
                if let error = coordinator.error, coordinator.group == nil {
                    ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                        .padding(RuulSpacing.lg)
                } else if coordinator.group == nil && coordinator.isLoading {
                    RuulLoadingState()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                            hero
                            summarySection
                            identitySection
                            peopleSection
                            rulesAndModulesSection
                            moneyAndZoneSection
                            pendingsSection
                            advancedSection
                        }
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.xs)
                        .padding(.bottom, RuulSpacing.s12)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await coordinator.refresh() }
                }
            }
        }
        .task { await coordinator.refresh() }
    }

    /// Slim hero: avatar + nombre + member count. El código de
    /// invitación se movió a la section IDENTIDAD (Apple Settings
    /// pattern) — antes hero hacía dos trabajos (identity display +
    /// invite share affordance) que cada uno merecía su lugar lógico.
    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: coordinator.group?.name ?? "?",
                imageURL: coordinator.group?.avatarUrl.flatMap(URL.init(string:)),
                size: .large
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.group?.name ?? "—")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                Text(memberLabel)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, RuulSpacing.md)
    }

    private var memberLabel: String {
        switch coordinator.memberCount {
        case 0: "Sin miembros"
        case 1: "1 miembro"
        default: "\(coordinator.memberCount) miembros"
        }
    }

    // MARK: - Refactored sections (Apple Settings pattern)
    //
    // Antes había una sección monolítica "CONFIGURACIÓN" con 7 items
    // mezclados (identidad, moneda, timezone, módulos, reglas, presets,
    // roles) + otra "COMUNIDAD" con cosas dispares (miembros, invitar,
    // votos, acciones). UX se sentía como volcadero. Ahora split en 5
    // buckets temáticos + AVANZADO destructive separado.

    /// 1. IDENTIDAD — quién es el grupo. Nombre + foto + código de
    ///    invitación (movido del hero para unificar settings).
    private var identitySection: some View {
        sectionContainer(title: "IDENTIDAD") {
            navRow(
                icon: "pencil",
                label: "Nombre y foto",
                action: { onEditIdentity?() }
            )
            if let code = coordinator.group?.inviteCode {
                divider
                navRow(
                    icon: "link",
                    label: code,
                    trailing: {
                        Text("Compartir")
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulAccent)
                    },
                    action: onShareInvite
                )
            }
        }
    }

    /// 2. PERSONAS — miembros, invitar nuevos, roles personalizados.
    ///    Todo lo relacionado con humanos en este grupo.
    private var peopleSection: some View {
        sectionContainer(title: "PERSONAS") {
            navRow(
                icon: "person.2",
                label: "Miembros",
                trailing: { trailingValue("\(coordinator.memberCount)") },
                action: {
                    coordinator.isCurrentUserAdmin
                        ? onOpenMembersAdmin?()
                        : onOpenMembersList?()
                }
            )
            if coordinator.isCurrentUserAdmin {
                divider
                navRow(
                    icon: "person.crop.circle.badge.plus",
                    label: "Invitar miembros",
                    action: { onInviteMembers?() }
                )
            }
            if coordinator.hasPermission(.assignRoles), let onOpenRoles {
                divider
                navRow(
                    icon: "person.text.rectangle",
                    label: "Roles y permisos",
                    trailing: { trailingValue("\(coordinator.group?.effectiveRoles.count ?? 2)") },
                    action: onOpenRoles
                )
            }
        }
    }

    /// 3. REGLAS Y MÓDULOS — qué capacidades tiene el grupo (módulos)
    ///    y qué normas aplican (rules + presets).
    private var rulesAndModulesSection: some View {
        sectionContainer(title: "REGLAS Y MÓDULOS") {
            navRow(
                icon: "puzzlepiece",
                label: "Módulos activos",
                trailing: { trailingValue("\(coordinator.activeModules.count)") },
                action: { onPickModules?() }
            )
            divider
            navRow(icon: "scale.3d", label: "Reglas del grupo", action: onOpenGovernance)
            divider
            navRow(icon: "list.bullet.clipboard", label: "Presets de reglas", action: onOpenRulePresets)
        }
    }

    /// 4. DINERO Y ZONA — settings de configuración ambiente. Moneda
    ///    para todo el ledger del grupo; timezone para cron de
    ///    notificaciones + display de fechas.
    private var moneyAndZoneSection: some View {
        sectionContainer(title: "DINERO Y ZONA") {
            navRow(
                icon: "dollarsign.circle",
                label: "Moneda",
                trailing: { trailingValue(coordinator.group?.currency ?? "—") },
                action: { onPickCurrency?() }
            )
            divider
            navRow(
                icon: "clock",
                label: "Zona horaria",
                trailing: { trailingValue(coordinator.group?.timezone ?? "—") },
                action: { onPickTimezone?() }
            )
        }
    }

    /// 5. PENDIENTES — accesos rápidos a cosas que requieren acción.
    ///    Solo se renderiza si hay 1+ pendiente; sin esto se ocultaba
    ///    detrás de COMUNIDAD y el usuario no se daba cuenta.
    @ViewBuilder
    private var pendingsSection: some View {
        let openVotes = coordinator.summary?.openVotesCount ?? 0
        let pendingActions = coordinator.summary?.pendingActionsCount ?? 0
        if openVotes > 0 || pendingActions > 0 {
            sectionContainer(title: "PENDIENTES") {
                if openVotes > 0 {
                    navRow(
                        icon: "hand.raised",
                        label: openVotes == 1
                            ? "1 voto abierto"
                            : "\(openVotes) votos abiertos",
                        action: { onOpenVotes?() }
                    )
                }
                if openVotes > 0 && pendingActions > 0 { divider }
                if pendingActions > 0 {
                    navRow(
                        icon: "tray.fill",
                        label: pendingActions == 1
                            ? "1 acción pendiente"
                            : "\(pendingActions) acciones pendientes",
                        action: { onOpenInbox?() }
                    )
                }
            }
        }
    }

    private var advancedSection: some View {
        sectionContainer(title: "AVANZADO") {
            navRow(icon: "arrow.triangle.2.circlepath", label: "Rotar código de invitación", action: { onRotateCode?() })
            if let onArchiveGroup {
                divider
                // Archivar es soft-delete: el grupo se oculta de la lista
                // pero su historia + ledger + atoms permanecen. Útil para
                // grupos pausados o estacionales (cenas de invierno, viaje
                // que terminó). Distinct de salir — el grupo sigue siendo
                // tuyo y puedes desarchivarlo.
                navRow(
                    icon: "archivebox",
                    label: "Archivar grupo",
                    action: onArchiveGroup,
                    destructive: true
                )
            }
            divider
            navRow(
                icon: "rectangle.portrait.and.arrow.right",
                label: "Salir del grupo",
                action: { onConfirmLeave?() ?? onLeaveGroup() },
                destructive: true
            )
        }
    }

    // MARK: Summary Section

    @ViewBuilder
    private var summarySection: some View {
        if let summary = coordinator.summary {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("RESUMEN")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .padding(.leading, RuulSpacing.xxs)
                HStack(spacing: RuulSpacing.sm) {
                    statTile(
                        value: "\(summary.memberCount)",
                        label: "Miembros",
                        action: { onOpenMembersList?() }
                    )
                    statTile(
                        value: "\(summary.upcomingEventsCount)",
                        label: "Próximos",
                        action: nil
                    )
                    statTile(
                        value: formatCurrency(summary.myBalanceCents, currency: summary.myBalanceCurrency),
                        label: "Mi balance",
                        action: onOpenMyLedger.map { cb in { cb() } }
                    )
                    if summary.pendingFinesCount > 0 {
                        statTile(
                            value: formatCurrency(summary.pendingFinesOutstandingCents, currency: summary.myBalanceCurrency),
                            label: "Multas",
                            action: onOpenMyFines.map { cb in { cb() } }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statTile(value: String, label: String, action: (() -> Void)?) -> some View {
        let content = VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text(value)
                .ruulTextStyle(RuulTypography.statMedium)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color.ruulSeparator, lineWidth: 0.5)
        )

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func formatCurrency(_ cents: Int64, currency: String) -> String {
        let units = Double(cents) / 100.0
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: units)) ?? "\(currency) \(Int(units))"
    }

    // MARK: Reusable

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, 56)
    }

    private func trailingValue(_ s: String) -> some View {
        Text(s)
            .ruulTextStyle(RuulTypography.caption)
            .foregroundStyle(Color.ruulTextSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func navRow(
        icon: String,
        label: String,
        trailing: () -> some View = { EmptyView() },
        action: @escaping () -> Void,
        destructive: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .ruulTextStyle(RuulTypography.subheadMedium)
                    .foregroundStyle(destructive ? Color.ruulNegative : Color.ruulTextSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(label)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(destructive ? Color.ruulNegative : Color.ruulTextPrimary)
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.captionBold)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
