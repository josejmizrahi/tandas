import SwiftUI
import RuulCore

/// F.1A-1 — Personal Settings. 6 secciones según la doctrina:
/// Perfil · Notificaciones · Privacidad · Calendario · Contexto · Integraciones.
/// La sección de Perfil reusa EditProfileView; las otras 5 muestran el estado
/// actual desde personal_settings_summary() y van anidando vistas conforme
/// cada slot reciba implementación real (este slice deja la mayoría como
/// "próximamente").
public struct PersonalSettingsView: View {
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw: String = AppearancePreference.system.rawValue
    @State private var store: PersonalSettingsStore
    @State private var isShowingEditProfile = false
    @State private var runner = ActionRunner()
    @State private var isConfirmingDeleteAccount = false
    @State private var deleteRunner = ActionRunner()
    @State private var changeContactKind: ChangeContactSheet.Kind?
    @State private var isConfirmingSignOut = false

    private var appearance: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    public init(container: DependencyContainer) {
        self.container = container
        _store = State(initialValue: PersonalSettingsStore(rpc: container.rpc))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .idle, .loading:
                    RuulLoadingState()
                case .failed(let message):
                    RuulErrorState(message: message) {
                        Task { await store.load() }
                    }
                case .loaded:
                    if let settings = store.settings {
                        settingsList(settings)
                    } else {
                        RuulErrorState(message: "No pudimos cargar tu configuración.")
                    }
                }
            }
            .navigationTitle("Configuración")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(isPresented: $isShowingEditProfile) {
            EditProfileView(container: container)
        }
        .actionErrorAlert(runner)
    }

    // MARK: - Lista

    @ViewBuilder
    private func settingsList(_ settings: PersonalSettings) -> some View {
        List {
            profileSection(settings.profile)
            appearanceSection
            notificationsSection(settings.notifications)
            privacySection(settings.privacy)
            calendarSection(settings.calendar)
            contextsSection(settings.contexts)
            integrationsSection(settings.integrations)
            legalSection

            Section {
                Button(role: .destructive) {
                    isConfirmingSignOut = true
                } label: {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            .confirmationDialog(
                "¿Cerrar sesión?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Cerrar sesión", role: .destructive) {
                    Task { await container.signOut() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Tu sesión se cerrará en este dispositivo.")
            }

            // FE.3 (V.1) — eliminación de cuenta (App Store 5.1.1(v) + ARCO).
            Section {
                Button(role: .destructive) {
                    isConfirmingDeleteAccount = true
                } label: {
                    Label("Eliminar cuenta", systemImage: "trash")
                }
                .disabled(deleteRunner.isRunning)
            } footer: {
                Text("Tu identidad se elimina de forma permanente. El historial de tus grupos se conserva de forma no identificable porque otros miembros dependen de él.")
            }
            .confirmationDialog(
                "¿Eliminar tu cuenta de forma permanente?",
                isPresented: $isConfirmingDeleteAccount,
                titleVisibility: .visible
            ) {
                Button("Eliminar cuenta", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Esta acción no se puede deshacer. Saldrás de todos tus espacios y tu nombre, teléfono y correo se eliminarán.")
            }
            .actionErrorAlert(deleteRunner)
        }
    }

    private func deleteAccount() async {
        let ok = await deleteRunner.run {
            try await container.rpc.deleteMyAccount()
        }
        if ok {
            // El backend ya borró las credenciales; signOut limpia el estado local.
            await container.signOut()
        }
    }

    // MARK: - Legal (V.2)

    @ViewBuilder
    private var legalSection: some View {
        Section("Legal") {
            Link(destination: URL(string: "https://ruul.mx/legal/privacy")!) {
                Label("Aviso de privacidad", systemImage: "hand.raised")
            }
            Link(destination: URL(string: "https://ruul.mx/legal/terms")!) {
                Label("Términos de servicio", systemImage: "doc.text")
            }
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Perfil

    @ViewBuilder
    private func profileSection(_ profile: PersonalProfileSummary) -> some View {
        Section("Perfil") {
            HStack(spacing: 12) {
                ActorInitialsView(name: profile.displayName, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.headline)
                    if let phone = profile.phone, !phone.isEmpty {
                        Text(phone).font(.caption).foregroundStyle(.secondary)
                    } else if let email = profile.email, !email.isEmpty {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if store.can("edit_profile") {
                Button {
                    isShowingEditProfile = true
                } label: {
                    Label("Editar perfil", systemImage: "pencil")
                }
            }

            // P1.3 — teléfono/correo editables vía OTP (antes read-only).
            Button {
                changeContactKind = .phone
            } label: {
                InfoRow(symbolName: "phone", title: "Teléfono",
                        value: (profile.phone?.isEmpty == false) ? profile.phone : "Agregar")
            }
            .foregroundStyle(.primary)
            Button {
                changeContactKind = .email
            } label: {
                InfoRow(symbolName: "envelope", title: "Email",
                        value: (profile.email?.isEmpty == false) ? profile.email : "Agregar")
            }
            .foregroundStyle(.primary)
        }
        .sheet(item: $changeContactKind) { kind in
            ChangeContactSheet(kind: kind, authService: container.authService) {
                Task {
                    await store.load()
                    await container.currentActorStore.load()
                }
            }
        }
    }

    // MARK: - Apariencia

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker(selection: appearance) {
                ForEach(AppearancePreference.allCases) { option in
                    Label(option.label, systemImage: option.systemImageName).tag(option)
                }
            } label: {
                Label("Apariencia", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.menu)
        } footer: {
            Text("Sistema sigue la configuración del dispositivo.")
        }
    }

    // MARK: - Notificaciones

    @ViewBuilder
    private func notificationsSection(_ notifications: NotificationSettings) -> some View {
        Section("Notificaciones") {
            ForEach(NotificationKey.allCases) { key in
                notificationRow(key: key, slot: notifications.slot(for: key))
            }
        }
    }

    @ViewBuilder
    private func notificationRow(key: NotificationKey, slot: NotificationSlot) -> some View {
        let canEdit = store.can("edit_notifications")
        HStack {
            Text(key.label)
            Spacer()
            Toggle("", isOn: Binding(
                get: { slot.push },
                set: { newValue in
                    guard canEdit else { return }
                    Task {
                        await runner.run {
                            try await store.setNotification(key, push: newValue)
                        }
                    }
                }
            ))
            .labelsHidden()
            .disabled(!canEdit || runner.isRunning)
        }
    }

    // MARK: - Privacidad

    private static let privacyOptions: [(value: String, label: String)] = [
        ("members_in_common", "Miembros en común"),
        ("anyone", "Cualquiera"),
        ("no_one", "Nadie"),
    ]

    @ViewBuilder
    private func privacySection(_ privacy: PrivacySettings) -> some View {
        let canEdit = store.can("edit_privacy")
        Section("Privacidad") {
            privacyPicker(
                title: "Quién puede encontrarme",
                systemImage: "person.crop.circle.badge.questionmark",
                key: .discoverableBy,
                current: privacy.discoverableBy,
                enabled: canEdit
            )
            privacyPicker(
                title: "Quién puede invitarme",
                systemImage: "envelope.badge",
                key: .whoCanInviteMe,
                current: privacy.whoCanInviteMe,
                enabled: canEdit
            )
            privacyPicker(
                title: "Visibilidad del perfil",
                systemImage: "eye",
                key: .profileVisibility,
                current: privacy.profileVisibility,
                enabled: canEdit
            )
        }
    }

    @ViewBuilder
    private func privacyPicker(title: String, systemImage: String, key: PrivacyKey, current: String, enabled: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Picker("", selection: Binding(
                get: { current },
                set: { newValue in
                    guard newValue != current, enabled else { return }
                    Task {
                        await runner.run {
                            try await store.setPrivacy(key, value: newValue)
                        }
                    }
                }
            )) {
                ForEach(Self.privacyOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .disabled(!enabled || runner.isRunning)
        }
    }

    // MARK: - Calendario

    /// Curado: zonas comunes para usuarios LATAM/US/EU del founder + actual del dispositivo.
    private static let timeZoneOptions: [String] = {
        var ids = [
            "America/Mexico_City", "America/Cancun", "America/Tijuana",
            "America/New_York", "America/Los_Angeles", "America/Chicago",
            "America/Bogota", "America/Lima", "America/Buenos_Aires",
            "America/Santiago", "America/Sao_Paulo",
            "Europe/Madrid", "Europe/London", "Europe/Paris",
            "UTC",
        ]
        let device = TimeZone.current.identifier
        if !ids.contains(device) { ids.insert(device, at: 0) }
        return ids
    }()

    @ViewBuilder
    private func calendarSection(_ calendar: CalendarSettings) -> some View {
        let canEdit = store.can("edit_calendar")
        Section("Calendario") {
            HStack {
                Label("Zona horaria", systemImage: "globe")
                Spacer()
                Picker("", selection: Binding(
                    get: { calendar.timeZone },
                    set: { newValue in
                        guard newValue != calendar.timeZone, canEdit else { return }
                        Task {
                            await runner.run {
                                try await store.setCalendar(.timeZone, value: newValue)
                            }
                        }
                    }
                )) {
                    ForEach(Self.timeZoneOptions, id: \.self) { tz in
                        Text(tz).tag(tz)
                    }
                }
                .labelsHidden()
                .disabled(!canEdit || runner.isRunning)
            }
            HStack {
                Label("Primer día de semana", systemImage: "calendar")
                Spacer()
                Picker("", selection: Binding(
                    get: { calendar.firstDayOfWeek },
                    set: { newValue in
                        guard newValue != calendar.firstDayOfWeek, canEdit else { return }
                        Task {
                            await runner.run {
                                try await store.setCalendar(.firstDayOfWeek, value: newValue)
                            }
                        }
                    }
                )) {
                    Text("Lunes").tag("monday")
                    Text("Domingo").tag("sunday")
                    Text("Sábado").tag("saturday")
                }
                .labelsHidden()
                .disabled(!canEdit || runner.isRunning)
            }
            Text("La sincronización con Google/Apple Calendar llega después.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Contexto

    @ViewBuilder
    private func contextsSection(_ contexts: ContextPreferences) -> some View {
        let canEdit = store.can("edit_contexts")
        let options = container.contextStore.collectiveContexts
        Section("Espacio") {
            HStack {
                Label("Espacio inicial", systemImage: "star")
                Spacer()
                Picker("", selection: Binding<UUID?>(
                    get: { contexts.defaultContextActorId },
                    set: { newValue in
                        guard newValue != contexts.defaultContextActorId, canEdit else { return }
                        Task {
                            await runner.run {
                                try await store.setDefaultContext(newValue)
                            }
                        }
                    }
                )) {
                    Text("No definido").tag(UUID?.none)
                    ForEach(options) { ctx in
                        Text(ctx.displayName).tag(Optional(ctx.id))
                    }
                }
                .labelsHidden()
                .disabled(!canEdit || runner.isRunning || options.isEmpty)
            }
            InfoRow(symbolName: "clock.arrow.circlepath",
                    title: "Último usado",
                    value: contexts.lastContextActorId == nil ? "—" : "Persistido")
            if options.isEmpty {
                Text("Cuando tengas espacios vas a poder elegir uno como inicial.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Integraciones
    //
    // R.13.A (founder lock 2026-06-16) — eliminado el placeholder branch
    // ("Próximamente" con 4 servicios futuros). Si ningún servicio externo
    // está conectado, la section no se renderea. Cuando una integración real
    // exista, se reactiva el branch `hasAny`.

    @ViewBuilder
    private func integrationsSection(_ integrations: IntegrationsState) -> some View {
        let hasAny = integrations.googleCalendar.connected
            || integrations.appleCalendar.connected
            || integrations.wise.connected
            || integrations.whatsapp.connected

        if hasAny {
            Section {
                if integrations.googleCalendar.connected {
                    integrationRow("Google Calendar", icon: "calendar", connected: true)
                }
                if integrations.appleCalendar.connected {
                    integrationRow("Apple Calendar", icon: "calendar.badge.checkmark", connected: true)
                }
                if integrations.wise.connected {
                    integrationRow("Wise", icon: "creditcard", connected: true)
                }
                if integrations.whatsapp.connected {
                    integrationRow("WhatsApp", icon: "message", connected: true)
                }
            } header: {
                Text("Integraciones")
            } footer: {
                Text("Conexiones activas con servicios externos.")
            }
        }
    }

    @ViewBuilder
    private func integrationRow(_ name: String, icon: String, connected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(name)
            Spacer()
            StatusBadge("Conectado", color: .green)
        }
    }
}

#Preview("Personal Settings") {
    PersonalSettingsView(container: .demo())
}
