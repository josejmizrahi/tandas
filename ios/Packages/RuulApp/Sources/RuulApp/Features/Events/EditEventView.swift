import SwiftUI
import RuulCore
import MapKit

/// F.EVENT.7 — editar un evento existente. Mismo shape de form que
/// `CreateEventView` pero precargado y atado a `update_calendar_event`.
/// Permisos: host del evento o `events.manage`. El backend re-valida.
public struct EditEventView: View {
    let event: CalendarEvent
    let context: AppContext
    let container: DependencyContainer
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var startsAt: Date
    @State private var endsAt: Date
    @State private var hasEndsAt: Bool
    @State private var locationText: String
    /// R.5V.3A.event — 3 modos de ubicación. `.perHost` sólo disponible para
    /// recurring semanal (doctrina F.EVENT.8). Espeja CreateEventView.
    @State private var locationMode: LocationMode
    @State private var recurrence: Recurrence
    @State private var runner = ActionRunner()
    @State private var locationCompleter = LocationCompleter()
    @State private var suppressNextQueryUpdate = false

    private enum Recurrence: String, CaseIterable, Identifiable {
        case none, daily, weekly, monthly, yearly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none:    return "No se repite"
            case .daily:   return "Diaria"
            case .weekly:  return "Semanal"
            case .monthly: return "Mensual"
            case .yearly:  return "Anual"
            }
        }
        var ruleValue: String? { self == .none ? nil : rawValue }
        static func from(_ raw: String?) -> Recurrence {
            guard let r = raw?.lowercased() else { return .none }
            return Recurrence(rawValue: r) ?? .none
        }
    }

    /// R.5V.3A.event — espeja CreateEventView.LocationMode.
    private enum LocationMode: String, CaseIterable, Identifiable {
        case physical, virtual, perHost
        var id: String { rawValue }
        var label: String {
            switch self {
            case .physical: return "En un lugar"
            case .virtual:  return "Virtual"
            case .perHost:  return "Por anfitrión"
            }
        }
        var symbol: String {
            switch self {
            case .physical: return "mappin.and.ellipse"
            case .virtual:  return "video.fill"
            case .perHost:  return "person.crop.circle.badge.questionmark"
            }
        }

        /// Deriva el modo inicial desde el evento (founder doctrina 2026-06-08):
        /// - virtual=true → .virtual
        /// - sin location → .perHost (siempre — se renderiza con label dinámico)
        /// - con location → .physical
        static func from(event: CalendarEvent) -> LocationMode {
            if event.isVirtual { return .virtual }
            let hasLocation = (event.locationText ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
            if !hasLocation { return .perHost }
            return .physical
        }
    }

    public init(
        event: CalendarEvent,
        context: AppContext,
        container: DependencyContainer,
        onSaved: @escaping () -> Void
    ) {
        self.event = event
        self.context = context
        self.container = container
        self.onSaved = onSaved
        _title = State(initialValue: event.title)
        _description = State(initialValue: event.description ?? "")
        _startsAt = State(initialValue: event.startsAt ?? Date())
        _endsAt = State(initialValue: event.endsAt ?? event.startsAt?.addingTimeInterval(2 * 3600) ?? Date().addingTimeInterval(2 * 3600))
        _hasEndsAt = State(initialValue: event.endsAt != nil)
        _locationText = State(initialValue: event.locationText ?? "")
        _locationMode = State(initialValue: LocationMode.from(event: event))
        _recurrence = State(initialValue: Recurrence.from(event.recurrenceRule))
    }

    private var locationIsValid: Bool {
        switch locationMode {
        case .physical: return !locationText.trimmingCharacters(in: .whitespaces).isEmpty
        case .virtual:  return true
        case .perHost:  return true
        }
    }

    private var perHostAvailable: Bool { true }

    /// Label dinámico para el 3er modo según recurrence (espeja CreateEventView).
    private var perHostLabel: String {
        recurrence == .weekly ? "Por anfitrión" : "Por definir"
    }

    private var perHostFooter: String {
        if recurrence == .weekly {
            return "El anfitrión actual decide dónde hospedar su semana. Cambia a “En un lugar” para fijar dirección de esta ocurrencia."
        }
        return "Puedes agregar la ubicación más tarde. Útil cuando todavía no decides el lugar."
    }

    /// 7.C.1 (audit 2026-06-14) — requiere `hasChanges` para no enviar updates
    /// vacíos. El backend ya devuelve diff_keys vacío en no-ops, pero queremos
    /// gatear el botón del lado iOS para que el usuario sepa que no cambió nada.
    private var canSubmit: Bool {
        isValid && hasChanges && !runner.isRunning
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && locationIsValid
            && (!hasEndsAt || endsAt >= startsAt)
    }

    private var hasChanges: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        let originalDescription = event.description ?? ""
        let originalLocation = event.locationText ?? ""
        let originalStartsAt = event.startsAt ?? startsAt
        let originalEndsAt = event.endsAt
        let originalRecurrence = Recurrence.from(event.recurrenceRule)
        let originalLocationMode = LocationMode.from(event: event)

        return trimmedTitle != event.title
            || trimmedDescription != originalDescription
            || startsAt != originalStartsAt
            || (hasEndsAt ? endsAt : nil) != originalEndsAt
            || trimmedLocation != originalLocation
            || locationMode != originalLocationMode
            || recurrence != originalRecurrence
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Evento") {
                    TextField("Título", text: $title)
                    TextField("Descripción (opcional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Cuándo") {
                    DatePicker("Inicio", selection: $startsAt)
                    Toggle("Definir fin", isOn: $hasEndsAt)
                    if hasEndsAt {
                        DatePicker("Fin", selection: $endsAt, in: startsAt...)
                    }
                }

                Section {
                    Picker("Frecuencia", selection: $recurrence) {
                        ForEach(Recurrence.allCases) { freq in
                            Text(freq.label).tag(freq)
                        }
                    }
                } header: {
                    Text("Recurrencia")
                } footer: {
                    if recurrence != .none {
                        Text("Al cerrar el evento se creará la próxima instancia automáticamente.")
                    }
                }

                // Ubicación va DESPUÉS de Recurrencia (founder UX 2026-06-08).
                Section {
                    Picker("Tipo de ubicación", selection: $locationMode) {
                        Label("En un lugar", systemImage: "mappin.and.ellipse").tag(LocationMode.physical)
                        Label("Virtual", systemImage: "video.fill").tag(LocationMode.virtual)
                        Label(perHostLabel, systemImage: "person.crop.circle.badge.questionmark").tag(LocationMode.perHost)
                    }
                    .pickerStyle(.menu)

                    if locationMode == .physical {
                        TextField("Dónde (dirección o lugar)", text: $locationText)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .onChange(of: locationText) { _, new in
                                if suppressNextQueryUpdate {
                                    suppressNextQueryUpdate = false
                                    return
                                }
                                locationCompleter.setQuery(new)
                            }
                        ForEach(locationCompleter.suggestions) { suggestion in
                            Button {
                                pickLocation(suggestion)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.tint)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.title)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        if !suggestion.subtitle.isEmpty {
                                            Text(suggestion.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Ubicación")
                } footer: {
                    switch locationMode {
                    case .physical:
                        Text("Si esta semana sabes dónde reciben, escríbelo aquí.")
                    case .virtual:
                        Text("Sin ubicación física.")
                    case .perHost:
                        Text(perHostFooter)
                    }
                }
            }
            .navigationTitle("Editar evento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        Task { await save() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func pickLocation(_ suggestion: LocationSuggestion) {
        let composed = suggestion.subtitle.isEmpty
            ? suggestion.title
            : "\(suggestion.title), \(suggestion.subtitle)"
        suppressNextQueryUpdate = true
        locationText = composed
        locationCompleter.clear()
    }

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        // R.5V.3A.event — payload por mode (espeja CreateEventView.create):
        // - physical: location_text=texto, is_virtual=false
        // - virtual:  location_text=nil,    is_virtual=true
        // - perHost:  location_text=nil,    is_virtual=false (host decide)
        let payloadLocation: String? = locationMode == .physical && !trimmedLocation.isEmpty
            ? trimmedLocation
            : nil
        let payloadVirtual: Bool = locationMode == .virtual
        // F.EVENT.10.1 — mandamos los valores actuales del form siempre. El
        // backend ya usa `coalesce(nullif(btrim(...), ''), existing)` para
        // detectar no-ops + devuelve diff_keys vacío cuando nada cambió.
        let input = UpdateEventInput(
            eventId: event.id,
            title: trimmedTitle,
            description: trimmedDescription,
            startsAt: startsAt,
            endsAt: hasEndsAt ? endsAt : nil,
            locationText: payloadLocation,
            isVirtual: payloadVirtual,
            recurrenceRule: recurrence.ruleValue
        )
        let success = await runner.run {
            _ = try await container.rpc.updateCalendarEvent(input)
        }
        if success {
            onSaved()
            dismiss()
        }
    }
}

#Preview("Editar evento") {
    EditEventView(
        event: CalendarEvent(
            id: UUID(),
            contextActorId: UUID(),
            title: "Cena viernes",
            description: "BYOB",
            eventType: "dinner",
            startsAt: Date().addingTimeInterval(86400),
            endsAt: Date().addingTimeInterval(86400 + 3 * 3600),
            locationText: "Casa Mizrahi",
            isVirtual: false,
            recurrenceRule: "weekly",
            hostActorId: UUID(),
            status: "scheduled"
        ),
        context: .init(id: UUID(), kind: .collective, subtype: "family", displayName: "Demo", memberCount: 3),
        container: .demo(),
        onSaved: {}
    )
}
