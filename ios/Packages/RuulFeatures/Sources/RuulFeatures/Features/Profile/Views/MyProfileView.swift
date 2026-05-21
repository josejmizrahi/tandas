import SwiftUI
import RuulUI
import RuulCore

/// Tab "Yo" — Layer 1 persistent identity per Ruul Identity & Context
/// Doctrine. One identity expressed through different contexts: this
/// surface shows the viewer's own STABLE, CROSS-GROUP identity — never
/// any group-scoped activity (that belongs in Inicio / Group home).
///
/// Apple Settings-flat structure: LargeTitle "Yo" + grouped `List` of
/// native `Section`s. References: Settings.app, Wallet settings,
/// Reminders settings sheet.
///
/// Layout:
///   - Profile hero (avatar + name + member count, no card chrome)
///   - "Mis grupos" — global participation summary (Layer 1)
///   - "Tu participación" — cross-group personal history (multas,
///     movimientos, timeline). NEVER group-scoped links.
///   - "Personal" — editar perfil
///   - "Notificaciones" — preferencias / dispositivos
///   - "Preferencias" — idioma / zona horaria
///   - "Apariencia" — inline picker
///   - "Cuenta" — teléfono / correo (Layer 1 contact methods)
///   - "Datos y cuenta" — exportar / eliminar (Layer 1 privacy)
///   - Cerrar sesión
///
/// Per Identity & Context Doctrine §2: Layer 1 should feel calm,
/// minimal, timeless — NOT operational or activity-heavy. Group-scoped
/// surfaces ("Actividad del grupo", "Historial del grupo") were removed
/// to keep this view strictly cross-group.
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
        // Profile es scalar — no aplica `.empty`. AsyncContentView sin
        // el builder `empty:` colapsa a EmptyView cuando el factory
        // `LoadPhase.from` nunca dispara `.empty` (la API siempre
        // devuelve un Profile o un error).
        AsyncContentView(
            phase: coordinator.phase,
            onRetry: { await coordinator.refresh() },
            loaded: { _ in loadedList }
        )
        .navigationTitle("Yo")
        .navigationBarTitleDisplayMode(.large)
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

    /// Apple Settings-flat list. `insetGrouped` matches Settings.app /
    /// Wallet / Reminders' settings sheet visual identity. Sections
    /// flow top to bottom following the founder doctrine's order.
    private var loadedList: some View {
        List {
            profileHeader
            myGroupsSection
            activitySection
            personalSection
            notificationsSection
            preferencesSection
            appearanceSection
            #if DEBUG
            debugSection
            #endif
            accountSection
            dataAndAccountSection
            signOutSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await coordinator.refresh() }
    }

    // MARK: - Profile hero (no card)

    /// Hero row at the top of the list. Wrapped in a `Section` with a
    /// transparent row background + hidden separator so it visually
    /// floats above the first card group — matching Apple's "Apple ID"
    /// header at the top of Settings.app.
    private var profileHeader: some View {
        Section {
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
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, RuulSpacing.sm)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: RuulSpacing.sm, trailing: 0))
        }
    }

    private var membershipMeta: String {
        let count = app.groups.count
        if count == 0 { return "Sin grupos" }
        if count == 1 { return "Miembro de 1 grupo" }
        return "Miembro de \(count) grupos"
    }

    // MARK: - Sections

    /// Up to 3 group rows + "Ver todos" overflow. Quick-switch surface;
    /// the dedicated "Mis grupos" tab is the drill-in to Group home.
    @ViewBuilder
    private var myGroupsSection: some View {
        if !app.groups.isEmpty {
            Section("Mis grupos") {
                ForEach(app.groups.prefix(3), id: \.id) { group in
                    groupRow(group)
                }
                if app.groups.count > 3, let onOpenGroupSwitcher {
                    Button(action: onOpenGroupSwitcher) {
                        Label("Ver todos (\(app.groups.count))", systemImage: "ellipsis.circle")
                    }
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
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer()
                if isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(isActive ? "\(group.name), grupo activo" : "Cambiar a \(group.name)")
    }

    /// Cross-group personal participation. Per Ruul Identity & Context
    /// Doctrine §2: Layer 1 (persistent identity) includes "global
    /// participation summary" — these rows surface the viewer's own
    /// cross-group history. NEVER group-specific activity links —
    /// those belong in Inicio / Group home, not in Yo.
    private var activitySection: some View {
        Section("Tu participación") {
            actionRow(label: "Mis multas", systemImage: "creditcard", trailing: {
                outstandingPill
            }, action: onOpenMyFines)
            if let onOpenMyLedger {
                actionRow(label: "Mis movimientos", systemImage: "arrow.left.arrow.right", action: onOpenMyLedger)
            }
            if let onOpenTimeline {
                actionRow(label: "Mi línea de tiempo", systemImage: "clock.badge.checkmark", action: onOpenTimeline)
            }
        }
    }

    private var personalSection: some View {
        Section("Personal") {
            actionRow(label: "Editar perfil", systemImage: "pencil", action: onEditProfile)
        }
    }

    private var notificationsSection: some View {
        Section("Notificaciones") {
            actionRow(label: "Preferencias", systemImage: "bell.badge", action: { onOpenNotificationPreferences?() })
            actionRow(label: "Dispositivos", systemImage: "iphone.and.arrow.forward", action: { onOpenDevices?() })
        }
    }

    private var preferencesSection: some View {
        Section("Preferencias") {
            actionRow(
                label: "Idioma",
                systemImage: "globe",
                value: localeLabel(coordinator.profile?.locale),
                action: { onPickLanguage?() }
            )
            actionRow(
                label: "Zona horaria",
                systemImage: "clock",
                value: coordinator.profile?.timezone ?? "—",
                action: { onPickTimezone?() }
            )
        }
    }

    /// Inline picker matches Apple Settings → Display & Brightness →
    /// Appearance. Native `Picker(.inline)` renders three Label rows
    /// with a checkmark on the active option — system handles the
    /// chrome and selection feedback. Drops the previous custom
    /// 3-button gallery card.
    private var appearanceSection: some View {
        Section("Apariencia") {
            Picker("Apariencia", selection: appearance) {
                ForEach(AppearanceOption.allCases) { option in
                    Label(option.label, systemImage: option.systemImage)
                        .tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var accountSection: some View {
        Section("Cuenta") {
            actionRow(
                label: "Teléfono",
                systemImage: "phone",
                value: coordinator.profile?.phone ?? "—",
                action: { onChangePhone?() }
            )
            actionRow(
                label: "Correo",
                systemImage: "envelope",
                value: app.session?.user.email ?? "—",
                action: { onChangeEmail?() }
            )
        }
    }

    /// LFPDPPP/CCPA right-to-portability + right-to-erasure surface. Solo
    /// se renderiza si el caller provee ambos callbacks (no tiene sentido
    /// mostrar solo uno — son derechos ARCO pareados).
    @ViewBuilder
    private var dataAndAccountSection: some View {
        if let onExportData, let onDeleteAccount {
            Section("Datos y cuenta") {
                actionRow(label: "Exportar mis datos", systemImage: "square.and.arrow.up", action: onExportData)
                Button(role: .destructive, action: onDeleteAccount) {
                    Label("Eliminar mi cuenta", systemImage: "trash")
                }
            }
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Cerrar sesión", role: .destructive) {
                showSignOutConfirm = true
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Outstanding fines pill

    @ViewBuilder
    private var outstandingPill: some View {
        if let amount = outstandingPillAmount, amount > 0 {
            Text(amountFormatted(amount))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.orange)
        }
    }

    // MARK: - Debug section (internal builds only)

    #if DEBUG
    /// Debug-only feature flag panel. Lets internal builds flip the new
    /// resource-creation flow on/off at runtime without rebuilding.
    /// Stripped from release builds entirely via `#if DEBUG`. Replace
    /// with a remote-config surface when the flag graduates from
    /// internal-only to runtime production rollout.
    @ViewBuilder
    private var debugSection: some View {
        Section("Debug") {
            Toggle(isOn: Binding(
                get: { ResourceCreationFeatureFlag.isEnabled },
                set: { ResourceCreationFeatureFlag.isEnabled = $0 }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Flow nuevo de crear recurso")
                        Text("Type → Variant → Identity → Create → Intents. Apagado vuelve al wizard de 5 pasos.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } icon: {
                    Image(systemName: "plus.app")
                }
            }
            // "Demote ResourceWizardSheet to Governance → Advanced"
            // landing pad. Without this, power users that wanted to
            // poke at the legacy 5-step wizard had to flip the flag
            // OFF, tap +, then flip back — clumsy. Now it's a direct
            // entry that works regardless of flag state. Requires
            // an active group (no-op otherwise) since the wizard's
            // first step assumes group scope.
            if app.activeGroup != nil {
                actionRow(
                    label: "Crear con opciones avanzadas",
                    systemImage: "wand.and.stars",
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

    // MARK: - Row helpers

    /// Canonical row: tappable `Button` with a `Label` (icon + title)
    /// leading, optional trailing value, and a tertiary chevron. List
    /// provides the background, separator, and tappable feedback. Used
    /// for both sheet-presenting rows and push destinations alike.
    @ViewBuilder
    private func actionRow<Trailing: View>(
        label: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Label(label, systemImage: systemImage)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: RuulSpacing.xs)
                trailing()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
    }

    private func actionRow(
        label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        actionRow(label: label, systemImage: systemImage, trailing: { EmptyView() }, action: action)
    }

    private func actionRow(
        label: String,
        systemImage: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        actionRow(label: label, systemImage: systemImage, trailing: {
            Text(value)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }, action: action)
    }

    private func localeLabel(_ code: String?) -> String {
        guard let code, let entry = LanguagePickerView.supported.first(where: { $0.code == code }) else { return "—" }
        return entry.label
    }

    private func amountFormatted(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "MXN"
        nf.maximumFractionDigits = 0
        return nf.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
