import SwiftUI
import RuulUI
import RuulCore

/// The "Yo" tab content. Replaces the old MyFinesView-as-tab pattern that
/// surfaced fines under a "Profile" label (confusing UX). Now MyFinesView
/// is a navigation destination accessible from here.
///
/// Layout (Apple Wallet × Apple Sports):
///   ┌───────────────────────────────────────┐
///   │  [Avatar]   José Mizrahi              │  hero
///   │             Miembro de 2 grupos        │
///   ├───────────────────────────────────────┤
///   │  TODO AL CORRIENTE  /  $300 PENDIENTE │  status hero
///   │                                        │
///   │  ┌──────┐  ┌──────┐  ┌──────┐          │  3 stat tiles
///   │  │ $300 │  │ $200 │  │  3   │          │
///   │  │ pend.│  │ pagas│  │multas│          │
///   │  └──────┘  └──────┘  └──────┘          │
///   ├───────────────────────────────────────┤
///   │  Mis multas                       →    │  nav row
///   │  Historia del grupo               →    │
///   ├───────────────────────────────────────┤
///   │  Ajustes                          →    │
///   ├───────────────────────────────────────┤
///   │  Cerrar sesión                         │  destructive
///   └───────────────────────────────────────┘
public struct ProfileView: View {
    @State var coordinator: ProfileCoordinator
    @Environment(AppState.self) private var app

    public let onOpenMyFines: () -> Void
    public let onOpenHistory: () -> Void
    public let onOpenSettings: () -> Void
    public let onEditProfile: () -> Void
    public let onSignOut: () -> Void
    /// "Mis movimientos" push (cross-group ledger summary). nil ⇒ no row.
    public var onOpenMyLedger: (() -> Void)? = nil

    /// DS v3 §6.2 — sección "Este grupo" (group-active scope). Cuando estos
    /// callbacks vienen non-nil, ProfileView renderiza la sección al final.
    /// Se mantienen opcionales para que ProfileView siga usable en contextos
    /// donde no haya grupo activo (auth bootstrap, anon stub).
    public var groupScope: GroupScopeContext? = nil

    public init(coordinator: ProfileCoordinator, onOpenMyFines: @escaping () -> Void, onOpenHistory: @escaping () -> Void, onOpenSettings: @escaping () -> Void, onEditProfile: @escaping () -> Void, onSignOut: @escaping () -> Void, onOpenMyLedger: (() -> Void)? = nil, groupScope: GroupScopeContext? = nil) {
        self._coordinator = State(initialValue: coordinator)
        self.onOpenMyFines = onOpenMyFines
        self.onOpenHistory = onOpenHistory
        self.onOpenSettings = onOpenSettings
        self.onEditProfile = onEditProfile
        self.onSignOut = onSignOut
        self.onOpenMyLedger = onOpenMyLedger
        self.groupScope = groupScope
    }

    public struct GroupScopeContext {
        let onOpenMembers: () -> Void
        let onOpenGovernance: () -> Void
        let onLeaveGroup: () -> Void
        /// Beta 1 Rule Builder entry. nil ⇒ row is hidden (mock/preview).
        let onOpenAcuerdos: (() -> Void)?

        public init(
            onOpenMembers: @escaping () -> Void,
            onOpenGovernance: @escaping () -> Void,
            onLeaveGroup: @escaping () -> Void,
            onOpenAcuerdos: (() -> Void)? = nil
        ) {
            self.onOpenMembers = onOpenMembers
            self.onOpenGovernance = onOpenGovernance
            self.onLeaveGroup = onLeaveGroup
            self.onOpenAcuerdos = onOpenAcuerdos
        }
    }

    public var body: some View {
        SwiftUI.Group {
            if let error = coordinator.error, coordinator.profile == nil {
                ErrorStateView(error: error, retry: { Task { await coordinator.refresh() } })
                    .padding(.horizontal, RuulSpacing.lg)
                    .padding(.top, RuulSpacing.lg)
                    .transition(.opacity)
            } else if coordinator.profile == nil && coordinator.isLoading {
                RuulLoadingState()
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                        hero
                        statusHero
                        if !coordinator.isAllClear {
                            statTiles
                        }
                        activitySection
                        settingsSection
                        if let groupScope { groupScopeSection(groupScope) }
                        signOutButton
                    }
                    .padding(.horizontal, RuulSpacing.lg)
                    .padding(.top, RuulSpacing.xs)
                    .padding(.bottom, RuulSpacing.s12)
                }
                .scrollIndicators(.hidden)
                .refreshable { await coordinator.refresh() }
                .transition(.opacity)
            }
        }
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.error)
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.isLoading)
        .animation(.linear(duration: RuulDuration.fast), value: coordinator.profile?.id)
        .ruulAmbientScreen(palette: nil)
        .task { await coordinator.refresh() }
    }

    // MARK: - Hero (avatar + name + group meta)

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: coordinator.profile?.displayName ?? "?",
                imageURL: coordinator.profile?.avatarUrl.flatMap(URL.init(string:)),
                size: .large
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.profile?.displayName ?? "—")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                Text(membershipMeta)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, RuulSpacing.md)
    }

    private var membershipMeta: String {
        let count = app.groups.count
        if count == 0 { return "Sin grupos" }
        if count == 1 { return "Miembro de 1 grupo" }
        return "Miembro de \(count) grupos"
    }

    // MARK: - Status hero (the big "you're caught up" or "you owe X")

    @ViewBuilder
    private var statusHero: some View {
        let isInteractive = !coordinator.isAllClear
        if isInteractive {
            Button(action: onOpenMyFines) {
                statusHeroContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            statusHeroContent
        }
    }

    private var statusHeroContent: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.xs) {
                Circle()
                    .fill(coordinator.isAllClear ? Color.ruulPositive : Color.ruulWarning)
                    .frame(width: 8, height: 8)
                Text(coordinator.isAllClear ? "TODO AL CORRIENTE" : "PENDIENTE DE PAGO")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Text(coordinator.isAllClear ? "Sin deudas" : amountFormatted(coordinator.totalOutstanding))
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Stat tiles (only when there's something to track)

    private var statTiles: some View {
        HStack(spacing: RuulSpacing.sm) {
            statTile(
                value: amountFormatted(coordinator.totalOutstanding),
                label: "Pendiente",
                action: onOpenMyFines
            )
            statTile(
                value: amountFormatted(coordinator.paidThisMonth),
                label: "Pagaste este mes",
                action: onOpenMyFines
            )
            statTile(
                value: "\(coordinator.totalFineCount)",
                label: "Multas totales",
                action: onOpenMyFines
            )
        }
    }

    private func statTile(value: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                Text(value)
                    .ruulTextStyle(RuulTypography.statMedium)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label.uppercased())
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RuulSpacing.md)
            .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    private var activitySection: some View {
        sectionContainer(title: "ACTIVIDAD") {
            navRow(icon: "creditcard", label: "Mis multas", trailing: { outstandingPill }, action: onOpenMyFines)
            if let onOpenMyLedger {
                divider
                navRow(icon: "arrow.left.arrow.right", label: "Mis movimientos", trailing: { EmptyView() }, action: onOpenMyLedger)
            }
            divider
            // W2-C5: "Historia" → "Actividad". The destination is the
            // group's system_events feed (ActivityView in
            // Features/Activity/), which is canonically named
            // "Actividad" per the UX dictionary.
            navRow(icon: "clock.arrow.circlepath", label: "Actividad del grupo", trailing: { EmptyView() }, action: onOpenHistory)
        }
    }

    private var settingsSection: some View {
        sectionContainer(title: "AJUSTES") {
            navRow(icon: "pencil", label: "Editar perfil", trailing: { EmptyView() }, action: onEditProfile)
            divider
            navRow(icon: "gearshape", label: "Ajustes", trailing: { EmptyView() }, action: onOpenSettings)
        }
    }

    @ViewBuilder
    private var outstandingPill: some View {
        if !coordinator.isAllClear {
            Text(amountFormatted(coordinator.totalOutstanding))
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulWarning)
        }
    }

    private var signOutButton: some View {
        Button(action: onSignOut) {
            Text("Cerrar sesión")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulNegative)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.md)
                .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: - Reusable section + row

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) {
                content()
            }
            .background(Color.ruulBackgroundCanvas, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private var divider: some View {
        Divider()
            .background(Color.ruulSeparator)
            .padding(.leading, 56)  // align with text after icon column
    }

    // MARK: - RuulCore.Group scope section (DS v3 §6.2 "Este grupo")

    @ViewBuilder
    private func groupScopeSection(_ scope: GroupScopeContext) -> some View {
        sectionContainer(title: "ESTE GRUPO") {
            navRow(
                icon: "person.2",
                label: "Miembros",
                trailing: { EmptyView() },
                action: scope.onOpenMembers
            )
            divider
            if let onOpenAcuerdos = scope.onOpenAcuerdos {
                navRow(
                    icon: "list.bullet.clipboard",
                    label: "Acuerdos",
                    trailing: { EmptyView() },
                    action: onOpenAcuerdos
                )
                divider
            }
            navRow(
                icon: "scale.3d",
                label: "Gobernanza",
                trailing: { soonPill },
                action: scope.onOpenGovernance,
                disabled: true
            )
            divider
            navRow(
                icon: "rectangle.portrait.and.arrow.right",
                label: "Salir del grupo",
                trailing: { EmptyView() },
                action: scope.onLeaveGroup,
                destructive: true
            )
        }
    }

    @ViewBuilder
    private var soonPill: some View {
        Text("PRONTO")
            .ruulTextStyle(RuulTypography.footnote)
            .foregroundStyle(Color.ruulTextTertiary)
    }

    @ViewBuilder
    private func navRow<Trailing: View>(
        icon: String,
        label: String,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void,
        disabled: Bool = false,
        destructive: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .ruulTextStyle(RuulTypography.subheadMedium)
                    .foregroundStyle(
                        disabled
                            ? Color.ruulTextTertiary
                            : (destructive ? Color.ruulNegative : Color.ruulTextSecondary)
                    )
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(label)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(
                        disabled
                            ? Color.ruulTextTertiary
                            : (destructive ? Color.ruulNegative : Color.ruulTextPrimary)
                    )
                Spacer()
                trailing()
                if !disabled {
                    Image(systemName: "chevron.right")
                        .ruulTextStyle(RuulTypography.captionBold)
                        .foregroundStyle(Color.ruulTextTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func amountFormatted(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
