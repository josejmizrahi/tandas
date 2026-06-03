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

    @ViewBuilder
    private func privacySection(_ privacy: PrivacySettings) -> some View {
        Section("Privacidad") {
            InfoRow(symbolName: "person.crop.circle.badge.questionmark",
                    title: "Quién puede encontrarme",
                    value: privacyLabel(privacy.discoverableBy))
            InfoRow(symbolName: "envelope.badge",
                    title: "Quién puede invitarme",
                    value: privacyLabel(privacy.whoCanInviteMe))
            InfoRow(symbolName: "eye",
                    title: "Visibilidad del perfil",
                    value: privacyLabel(privacy.profileVisibility))
            Text("Estos ajustes serán configurables en una próxima versión.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func privacyLabel(_ raw: String) -> String {
        switch raw {
        case "members_in_common": return "Miembros en común"
        case "anyone":             return "Cualquiera"
        case "no_one":             return "Nadie"
        default:                   return raw
        }
    }

    // MARK: - Calendario

    @ViewBuilder
    private func calendarSection(_ calendar: CalendarSettings) -> some View {
        Section("Calendario") {
            InfoRow(symbolName: "globe", title: "Zona horaria", value: calendar.timeZone)
            InfoRow(symbolName: "calendar", title: "Primer día de semana", value: weekStartLabel(calendar.firstDayOfWeek))
            Text("La sincronización con Google/Apple Calendar llega después.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func weekStartLabel(_ raw: String) -> String {
        switch raw {
        case "monday": return "Lunes"
        case "sunday": return "Domingo"
        case "saturday": return "Sábado"
        default: return raw.capitalized
        }
    }

    // MARK: - Contexto

    @ViewBuilder
    private func contextsSection(_ contexts: ContextPreferences) -> some View {
        Section("Contexto") {
            InfoRow(symbolName: "star",
                    title: "Contexto inicial",
                    value: contexts.defaultContextActorId == nil ? "No definido" : "Configurado")
            InfoRow(symbolName: "clock.arrow.circlepath",
                    title: "Último usado",
                    value: contexts.lastContextActorId == nil ? "—" : "Persistido")
            Text("Pronto vas a poder elegir un contexto inicial por defecto.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
