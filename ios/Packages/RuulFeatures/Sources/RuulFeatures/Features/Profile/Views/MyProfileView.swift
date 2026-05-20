import SwiftUI
import RuulUI
import RuulCore

/// Tab "Yo" — Nivel 0 (Identity, cross-group). Shows the user's own
/// profile and cross-group activity entry points only. No group-active
/// state leaks into this view.
///
/// Layout (V2 Slice 4G — Profile partition):
///   Always visible:
///     Hero (avatar + name + "Miembro de N grupos")
///     Segmented control: Tú · Cuenta
///   Tab "Tú" (default):
///     MIS GRUPOS · TU ACTIVIDAD · AJUSTES · PREFERENCIAS · APARIENCIA · DEBUG
///   Tab "Cuenta":
///     IDENTIDAD (teléfono + correo) · NOTIFICACIONES · DATOS Y CUENTA · Cerrar sesión
///
/// Per V2 Plan §B.3: account-ops (identity, notifications, data, sign
/// out) group under Cuenta; "you-as-a-person" surfaces (groups,
/// activity, edit profile, display preferences, theme) live under Tú.
public struct MyProfileView: View {
    @State var coordinator: ProfileCoordinator
    @Environment(AppState.self) private var app
    @AppStorage("ruul_appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue

    public let onOpenMyFines: () -> Void
    public let onOpenHistory: () -> Void
    public let onEditProfile: () -> Void
    public let onSignOut: () -> Void
    public var onOpenMyLedger: (() -> Void)? = nil
    public var onOpenTimeline: (() -> Void)? = nil

    /// Cross-group outstanding fines pill (read from MyFinesCoordinator).
    /// nil while loading or when zero.
    public var outstandingPillAmount: Decimal?

    public var onChangePhone: (() -> Void)?
    public var onChangeEmail: (() -> Void)?
    public var onPickLanguage: (() -> Void)?
    public var onPickTimezone: (() -> Void)?
    public var onOpenNotificationPreferences: (() -> Void)?
    public var onOpenDevices: (() -> Void)?
    public var onOpenGroupSwitcher: (() -> Void)?
    public var onExportData: (() -> Void)?
    public var onDeleteAccount: (() -> Void)?

    @State private var showSignOutConfirm = false
    #if DEBUG
    /// Drives the legacy ResourceWizardSheet cover for "Crear con
    /// opciones avanzadas" — the demoted entry point for the 5-step
    /// wizard that still surfaces capability toggles. Internal-only:
    /// release builds strip this state entirely via the section gate.
    @State private var legacyWizardPresented = false
    #endif

    /// V2 Slice 4G — Profile sub-tab. Defaults to `.tú` so the user
    /// sees themselves + their activity first; account-ops (phone,
    /// email, notifications, data, sign out) live a tap away in
    /// `.cuenta`.
    public enum SubTab: Hashable, CaseIterable, Sendable {
        case tú
        case cuenta

        public var label: String {
            switch self {
            case .tú:     return "Tú"
            case .cuenta: return "Cuenta"
            }
        }
    }
    @State private var subTab: SubTab = .tú

    public init(
        coordinator: ProfileCoordinator,
        onOpenMyFines: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onEditProfile: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
        onOpenMyLedger: (() -> Void)? = nil,
        onOpenTimeline: (() -> Void)? = nil,
        outstandingPillAmount: Decimal? = nil,
        onChangePhone: (() -> Void)? = nil,
        onChangeEmail: (() -> Void)? = nil,
        onPickLanguage: (() -> Void)? = nil,
        onPickTimezone: (() -> Void)? = nil,
        onOpenNotificationPreferences: (() -> Void)? = nil,
        onOpenDevices: (() -> Void)? = nil,
        onOpenGroupSwitcher: (() -> Void)? = nil,
        onExportData: (() -> Void)? = nil,
        onDeleteAccount: (() -> Void)? = nil
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onOpenMyFines = onOpenMyFines
        self.onOpenHistory = onOpenHistory
        self.onEditProfile = onEditProfile
        self.onSignOut = onSignOut
        self.onOpenMyLedger = onOpenMyLedger
        self.onOpenTimeline = onOpenTimeline
        self.outstandingPillAmount = outstandingPillAmount
        self.onChangePhone = onChangePhone
        self.onChangeEmail = onChangeEmail
        self.onPickLanguage = onPickLanguage
        self.onPickTimezone = onPickTimezone
        self.onOpenNotificationPreferences = onOpenNotificationPreferences
        self.onOpenDevices = onOpenDevices
        self.onOpenGroupSwitcher = onOpenGroupSwitcher
        self.onExportData = onExportData
        self.onDeleteAccount = onDeleteAccount
    }

    private var appearance: Binding<AppearanceOption> {
        Binding(
            get: { AppearanceOption(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            // Profile es scalar — no aplica `.empty`. AsyncContentView
            // sin el builder `empty:` colapsa a `EmptyView` cuando el
            // factory `LoadPhase.from` nunca dispara `.empty` (es el
            // caso aquí: la API siempre devuelve un Profile o un error).
            AsyncContentView(
                phase: coordinator.phase,
                onRetry: { await coordinator.refresh() },
                loaded: { _ in loadedScroll }
            )
        }
        .ruulAppToolbar(showsGroupAvatar: false)
        .task { await coordinator.refresh() }
        .confirmationDialog(
            "¿Salir de tu cuenta?",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Cerrar sesión", role: .destructive, action: onSignOut)
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tus grupos, multas e historia siguen guardados. Vuelves a entrar con el mismo teléfono o Apple ID.")
        }
    }

    /// Scroll contenedor del Profile cargado. Extraído para que el
    /// `loaded` builder de `AsyncContentView` quede declarativo.
    private var loadedScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                hero
                // V2 Slice 4G sub-tab chrome. Two segments only — fits
                // iPhone SE width with room to spare. Hero stays above
                // so the user always sees who they are.
                RuulSegmentedControl(
                    selection: $subTab,
                    segments: SubTab.allCases.map { ($0, $0.label) }
                )
                switch subTab {
                case .tú:
                    myGroupsSection
                    activitySection
                    settingsSection
                    preferencesSection
                    appearanceSection
                    #if DEBUG
                    debugSection
                    #endif
                case .cuenta:
                    identitySection
                    notificationsSection
                    dataAndAccountSection
                    signOutButton
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    // MARK: Hero (avatar + name + cross-group meta)

    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: coordinator.profile?.displayName ?? "?",
                imageURL: coordinator.profile?.avatarUrl.flatMap(URL.init(string:)),
                size: .large
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.profile?.displayName ?? "—")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(membershipMeta)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
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

    // MARK: Sections

    private var identitySection: some View {
        sectionContainer(title: "IDENTIDAD") {
            navRow(
                icon: "phone",
                label: "Teléfono",
                trailing: { trailingValue(coordinator.profile?.phone ?? "—") },
                action: { onChangePhone?() }
            )
            divider
            navRow(
                icon: "envelope",
                label: "Correo",
                trailing: { trailingValue(app.session?.user.email ?? "—") },
                action: { onChangeEmail?() }
            )
        }
    }

    private var preferencesSection: some View {
        sectionContainer(title: "PREFERENCIAS") {
            navRow(
                icon: "globe",
                label: "Idioma",
                trailing: { trailingValue(localeLabel(coordinator.profile?.locale)) },
                action: { onPickLanguage?() }
            )
            divider
            navRow(
                icon: "clock",
                label: "Zona horaria",
                trailing: { trailingValue(coordinator.profile?.timezone ?? "—") },
                action: { onPickTimezone?() }
            )
        }
    }

    private var notificationsSection: some View {
        sectionContainer(title: "NOTIFICACIONES") {
            navRow(
                icon: "bell.badge",
                label: "Preferencias",
                trailing: { EmptyView() },
                action: { onOpenNotificationPreferences?() }
            )
            divider
            navRow(
                icon: "iphone.and.arrow.forward",
                label: "Dispositivos",
                trailing: { EmptyView() },
                action: { onOpenDevices?() }
            )
        }
    }

    private func trailingValue(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func localeLabel(_ code: String?) -> String {
        guard let code, let entry = LanguagePickerView.supported.first(where: { $0.code == code }) else { return "—" }
        return entry.label
    }

    /// Lista los primeros 3 grupos del usuario con tap-to-switch + un
    /// "Ver todos" cuando hay más. Antes el switcher estaba solo en el
    /// header del Home, lo que para usuarios con 5+ grupos lo volvía
    /// invisible. El active group queda marcado con dot accent.
    @ViewBuilder
    private var myGroupsSection: some View {
        if !app.groups.isEmpty {
            sectionContainer(title: "MIS GRUPOS") {
                let visible = Array(app.groups.prefix(3))
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, group in
                    if idx > 0 { divider }
                    groupRow(group)
                }
                if app.groups.count > 3, let onOpenGroupSwitcher {
                    divider
                    navRow(
                        icon: "ellipsis",
                        label: "Ver todos (\(app.groups.count))",
                        trailing: { EmptyView() },
                        action: onOpenGroupSwitcher
                    )
                }
            }
        }
    }

    private func groupRow(_ group: RuulCore.Group) -> some View {
        let isActive = app.activeGroup?.id == group.id
        return Button {
            if !isActive {
                app.activeGroupId = group.id
                RuulHaptic.groupSwitch.trigger()
            }
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                RuulGroupAvatar(group: group, size: .md)
                Text(group.name)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer()
                if isActive {
                    Circle().fill(Color.ruulAccent).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "\(group.name), grupo activo" : "Cambiar a \(group.name)")
    }

    private var activitySection: some View {
        sectionContainer(title: "TU ACTIVIDAD") {
            navRow(icon: "creditcard", label: "Mis multas", trailing: { outstandingPill }, action: onOpenMyFines)
            if let onOpenMyLedger {
                divider
                navRow(icon: "arrow.left.arrow.right", label: "Mis movimientos", trailing: { EmptyView() }, action: onOpenMyLedger)
            }
            divider
            navRow(icon: "clock.badge.checkmark", label: "Mi línea de tiempo", trailing: { EmptyView() }, action: { onOpenTimeline?() })
            divider
            navRow(icon: "clock.arrow.circlepath", label: "Actividad del grupo", trailing: { EmptyView() }, action: onOpenHistory)
        }
    }

    private var settingsSection: some View {
        sectionContainer(title: "AJUSTES") {
            navRow(icon: "pencil", label: "Editar perfil", trailing: { EmptyView() }, action: onEditProfile)
        }
    }

    #if DEBUG
    /// Debug-only feature flag panel. Lets internal builds flip the new
    /// resource-creation flow on/off at runtime without rebuilding.
    /// Stripped from release builds entirely via `#if DEBUG`. Replace
    /// with a remote-config surface when the flag graduates from
    /// internal-only to runtime production rollout.
    private var debugSection: some View {
        sectionContainer(title: "DEBUG") {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "plus.app")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flow nuevo de crear recurso")
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    Text("Type → Variant → Identity → Create → Intents. Apagado vuelve al wizard de 5 pasos.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { ResourceCreationFeatureFlag.isEnabled },
                    set: { ResourceCreationFeatureFlag.isEnabled = $0 }
                ))
                .labelsHidden()
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            // "Demote ResourceWizardSheet to Governance → Advanced"
            // landing pad. Without this, power users that wanted to
            // poke at the legacy 5-step wizard had to flip the flag
            // OFF, tap +, then flip back — clumsy. Now it's a direct
            // entry that works regardless of flag state. Requires
            // an active group (no-op otherwise) since the wizard's
            // first step assumes group scope.
            if app.activeGroup != nil {
                navRow(
                    icon: "wand.and.stars",
                    label: "Crear con opciones avanzadas",
                    trailing: { EmptyView() },
                    action: { legacyWizardPresented = true }
                )
            }
        }
        .fullScreenCover(isPresented: $legacyWizardPresented) {
            if let group = app.activeGroup {
                ResourceWizardSheet(
                    group: group,
                    suggestedDate: Date().addingTimeInterval(86_400 + 20*3600),
                    onCreated: { _ in legacyWizardPresented = false }
                )
            }
        }
    }
    #endif

    /// LFPDPPP/CCPA right-to-portability + right-to-erasure surface. Solo
    /// se renderiza si el caller provee ambos callbacks (no tiene sentido
    /// mostrar solo uno — son derechos ARCO pareados).
    @ViewBuilder
    private var dataAndAccountSection: some View {
        if let onExportData, let onDeleteAccount {
            sectionContainer(title: "DATOS Y CUENTA") {
                navRow(
                    icon: "square.and.arrow.up",
                    label: "Exportar mis datos",
                    trailing: { EmptyView() },
                    action: onExportData
                )
                divider
                navRow(
                    icon: "trash",
                    label: "Eliminar mi cuenta",
                    trailing: { EmptyView() },
                    action: onDeleteAccount,
                    destructive: true
                )
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("APARIENCIA")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)
            HStack(spacing: RuulSpacing.xs) {
                ForEach(AppearanceOption.allCases) { option in
                    Button {
                        appearance.wrappedValue = option
                    } label: {
                        VStack(spacing: RuulSpacing.xxs) {
                            Image(systemName: option.systemImage)
                                .font(.title2.weight(.medium))
                                .accessibilityHidden(true)
                            Text(option.label)
                                .font(.footnote)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.md)
                        .foregroundStyle(
                            appearance.wrappedValue == option
                                ? Color.primary
                                : Color.secondary
                        )
                        .background(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .fill(
                                    appearance.wrappedValue == option
                                        ? Color.ruulBackgroundRecessed
                                        : Color.ruulSurface
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                                .stroke(
                                    appearance.wrappedValue == option
                                        ? Color.ruulBorderStrong
                                        : Color(.separator),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: appearance.wrappedValue)
                }
            }
        }
    }

    @ViewBuilder
    private var outstandingPill: some View {
        if let amount = outstandingPillAmount, amount > 0 {
            Text(amountFormatted(amount))
                .font(.footnote.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.orange)
        }
    }

    private var signOutButton: some View {
        Button { showSignOutConfirm = true } label: {
            Text("Cerrar sesión")
                .font(.subheadline)
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.md)
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
        }
        .buttonStyle(.ruulPress)
    }

    // MARK: Reusable section + row

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
    }

    private var divider: some View {
        Divider().background(Color(.separator)).padding(.leading, 56)
    }

    @ViewBuilder
    private func navRow<Trailing: View>(
        icon: String,
        label: String,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void,
        destructive: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(destructive ? Color.red : Color.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func amountFormatted(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
