import SwiftUI
import RuulUI
import RuulCore

/// Nivel 1 home — the group as a persistent social domain.
/// Layout:
///   Hero (avatar + name + invite code + member count)
///   CONFIGURACIÓN (vocabulary + governance link in Pass 1; Pass 2 adds the rest)
///   COMUNIDAD (members + group activity in Pass 3)
///   AVANZADO (leave; Pass 2 adds rotate code; Pass 4 adds archive)
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
                            configurationSection
                            communitySection
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

    private var hero: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
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

            if let code = coordinator.group?.inviteCode {
                Button(action: onShareInvite) {
                    HStack(spacing: RuulSpacing.xs) {
                        Image(systemName: "link")
                            .ruulTextStyle(RuulTypography.subheadMedium)
                            .accessibilityHidden(true)
                        Text(code)
                            .ruulTextStyle(RuulTypography.mono)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                        Text("Compartir")
                            .ruulTextStyle(RuulTypography.callout)
                            .foregroundStyle(Color.ruulAccent)
                    }
                    .padding(RuulSpacing.md)
                    .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.md)
                            .stroke(Color.ruulSeparator, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
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

    private var configurationSection: some View {
        sectionContainer(title: "CONFIGURACIÓN") {
            navRow(icon: "pencil", label: "Nombre y foto", action: { onEditIdentity?() })
            divider
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
            divider
            navRow(
                icon: "puzzlepiece",
                label: "Módulos",
                trailing: { trailingValue("\(coordinator.activeModules.count) activos") },
                action: { onPickModules?() }
            )
            divider
            navRow(icon: "scale.3d", label: "Reglas del grupo", action: onOpenGovernance)
            divider
            navRow(icon: "list.bullet.clipboard", label: "Presets de reglas", action: onOpenRulePresets)
            if coordinator.hasPermission(.assignRoles), let onOpenRoles {
                divider
                navRow(
                    icon: "person.text.rectangle",
                    label: "Roles y permisos",
                    trailing: { trailingValue(rolesSummary) },
                    action: onOpenRoles
                )
            }
        }
    }

    private var rolesSummary: String {
        let total = coordinator.group?.effectiveRoles.count ?? 2
        switch total {
        case 0, 1: return "\(total)"
        default:   return "\(total)"
        }
    }

    private var communitySection: some View {
        sectionContainer(title: "COMUNIDAD") {
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
            if let summary = coordinator.summary, summary.openVotesCount > 0 {
                divider
                navRow(
                    icon: "hand.raised",
                    label: summary.openVotesCount == 1
                        ? "1 voto abierto"
                        : "\(summary.openVotesCount) votos abiertos",
                    action: { onOpenVotes?() }
                )
            }
            if let summary = coordinator.summary, summary.pendingActionsCount > 0 {
                divider
                navRow(
                    icon: "tray.fill",
                    label: summary.pendingActionsCount == 1
                        ? "1 acción pendiente"
                        : "\(summary.pendingActionsCount) acciones pendientes",
                    action: { onOpenInbox?() }
                )
            }
        }
    }

    private var advancedSection: some View {
        sectionContainer(title: "AVANZADO") {
            navRow(icon: "arrow.triangle.2.circlepath", label: "Rotar código de invitación", action: { onRotateCode?() })
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
