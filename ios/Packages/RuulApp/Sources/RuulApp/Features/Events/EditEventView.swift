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
    @State private var isVirtual: Bool
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
        _isVirtual = State(initialValue: event.isVirtual)
        _recurrence = State(initialValue: Recurrence.from(event.recurrenceRule))
    }

    private var locationIsValid: Bool {
        isVirtual || !locationText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && locationIsValid
            && (!hasEndsAt || endsAt >= startsAt)
            && !runner.isRunning
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
                    Toggle(isOn: $isVirtual) {
                        Label("Evento virtual", systemImage: "video.fill")
                    }
                    if !isVirtual {
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
                    if isVirtual {
                        Text("Sin ubicación física.")
                    } else {
                        Text("La ubicación es obligatoria si el evento no es virtual.")
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
        // Sólo mandamos campos que cambiaron — NULL = "no cambiar" en el backend.
        let input = UpdateEventInput(
            eventId: event.id,
            title: trimmedTitle == event.title ? nil : trimmedTitle,
            description: trimmedDescription == (event.description ?? "") ? nil : trimmedDescription,
            startsAt: startsAt == event.startsAt ? nil : startsAt,
            endsAt: (hasEndsAt ? endsAt : nil) == event.endsAt ? nil : (hasEndsAt ? endsAt : nil),
            locationText: isVirtual ? nil : (trimmedLocation == (event.locationText ?? "") ? nil : trimmedLocation),
            isVirtual: isVirtual == event.isVirtual ? nil : isVirtual,
            recurrenceRule: recurrence.ruleValue == event.recurrenceRule ? nil : recurrence.ruleValue
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
