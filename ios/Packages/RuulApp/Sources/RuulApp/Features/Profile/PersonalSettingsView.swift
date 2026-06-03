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
    @State private var store: PersonalSettingsStore
    @State private var isShowingEditProfile = false
    @State private var runner = ActionRunner()

    public init(container: DependencyContainer) {
        self.container = container
        _store = State(initialValue: PersonalSettingsStore(rpc: container.rpc))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .idle, .loading:
                    LoadingStateView()
                case .failed(let message):
                    ErrorStateView(message: message) {
                        Task { await store.load() }
                    }
                case .loaded:
                    if let settings = store.settings {
                        settingsList(settings)
                    } else {
                        ErrorStateView(message: "No pudimos cargar tu configuración.")
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
            notificationsSection(settings.notifications)
            privacySection(settings.privacy)
            calendarSection(settings.calendar)
            contextsSection(settings.contexts)
            integrationsSection(settings.integrations)

            Section {
                Button(role: .destructive) {
                    Task { await container.signOut() }
                } label: {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
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

            if let phone = profile.phone, !phone.isEmpty {
                InfoRow(symbolName: "phone", title: "Teléfono", value: phone)
            }
            if let email = profile.email, !email.isEmpty {
                InfoRow(symbolName: "envelope", title: "Email", value: email)
            }
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
        Section("Contexto") {
            HStack {
                Label("Contexto inicial", systemImage: "star")
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
                Text("Cuando tengas contextos vas a poder elegir uno como inicial.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Integraciones

    @ViewBuilder
    private func integrationsSection(_ integrations: IntegrationsState) -> some View {
        Section("Integraciones") {
            integrationRow("Google Calendar", icon: "calendar", connected: integrations.googleCalendar.connected)
            integrationRow("Apple Calendar", icon: "calendar.badge.checkmark", connected: integrations.appleCalendar.connected)
            integrationRow("Wise", icon: "creditcard", connected: integrations.wise.connected)
            integrationRow("WhatsApp", icon: "message", connected: integrations.whatsapp.connected)
            Text("Las integraciones llegan en próximas versiones.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            StatusBadge(connected ? "Conectado" : "Próximamente",
                        color: connected ? .green : .gray)
        }
    }
}

#Preview("Personal Settings") {
    PersonalSettingsView(container: .demo())
}
