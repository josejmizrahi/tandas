import SwiftUI
import RuulCore
import MapKit

/// F.7 — crear un evento (cena, reunión, viaje, noche de juegos…).
public struct CreateEventView: View {
    let context: AppContext
    let store: EventsStore
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var eventType: EventType = .dinner
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var locationText = ""
    @State private var isVirtual = false
    @State private var recurrence: Recurrence = .none
    /// F.EVENT.9 — cómo se acota la serie. `.indefinite` = sin fin.
    @State private var seriesBound: SeriesBound = .indefinite
    @State private var occurrenceCountText = "10"
    @State private var seriesUntil = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var inviteAllMembers = true
    @State private var runner = ActionRunner()
    /// F.EVENT.7 — Apple Maps autocomplete vía MKLocalSearchCompleter.
    @State private var locationCompleter = LocationCompleter()
    @State private var suppressNextQueryUpdate = false

    /// F.EVENT.9 — tres modos de acotar la serie.
    private enum SeriesBound: String, CaseIterable, Identifiable {
        case indefinite, count, until
        var id: String { rawValue }
        var label: String {
            switch self {
            case .indefinite: return "Sin fin"
            case .count:      return "N veces"
            case .until:      return "Hasta fecha"
            }
        }
    }

    /// F.EVENT.6 — frecuencias soportadas. El backend `close_event` interpreta
    /// el `rawValue` para auto-crear la siguiente instancia (weekly rota host;
    /// daily/monthly/yearly mantienen host).
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
        var ruleValue: String? {
            self == .none ? nil : rawValue
        }
    }

    public init(context: AppContext, store: EventsStore, container: DependencyContainer) {
        self.context = context
        self.store = store
        self.container = container
    }

    /// F.EVENT.5 — un evento siempre debe tener ubicación, salvo que sea virtual.
    private var locationIsValid: Bool {
        isVirtual || !locationText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// F.EVENT.9 — validación del bound elegido. `count` debe ser entero > 0.
    private var seriesBoundIsValid: Bool {
        guard recurrence != .none else { return true }
        switch seriesBound {
        case .indefinite: return true
        case .count:      return parsedOccurrenceCount.map { $0 > 0 } ?? false
        case .until:      return seriesUntil > startsAt
        }
    }

    private var parsedOccurrenceCount: Int? {
        Int(occurrenceCountText.trimmingCharacters(in: .whitespaces))
    }

    /// Binding bridge entre `String` y `Int` para el Stepper.
    private var occurrenceCountBinding: Binding<Int> {
        Binding(
            get: { parsedOccurrenceCount ?? 1 },
            set: { occurrenceCountText = String($0) }
        )
    }

    @ViewBuilder
    private var seriesBoundFooter: some View {
        switch seriesBound {
        case .indefinite:
            Text("La serie continúa hasta que alguien cierre la última instancia.")
        case .count:
            if let count = parsedOccurrenceCount, count > 0 {
                Text("Se crearán hasta \(count) ocurrencias en total.")
            } else {
                Text("Indica cuántas ocurrencias quieres.")
            }
        case .until:
            Text("La serie termina al pasar esta fecha.")
        }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && locationIsValid
            && seriesBoundIsValid
            && !runner.isRunning
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Evento") {
                    TextField("Título (Cena de los jueves…)", text: $title)
                    Picker("Tipo", selection: $eventType) {
                        ForEach(EventType.allCases) { type in
                            Label(type.label, systemImage: type.symbolName).tag(type)
                        }
                    }
                    DatePicker("Cuándo", selection: $startsAt)
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
                        Text("Sin ubicación física. Después puedes compartir el link del Zoom o Meet.")
                    } else {
                        Text("La ubicación es obligatoria. Si el evento es por videollamada, activa \"Evento virtual\".")
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
                    switch recurrence {
                    case .none:
                        EmptyView()
                    case .weekly:
                        Text("Al cerrar cada evento se crea automáticamente el de la siguiente semana y el host rota entre los miembros.")
                    case .daily:
                        Text("Al cerrar cada evento se crea el del día siguiente con el mismo host.")
                    case .monthly:
                        Text("Al cerrar cada evento se crea el del mes siguiente con el mismo host.")
                    case .yearly:
                        Text("Al cerrar cada evento se crea el del año siguiente con el mismo host.")
                    }
                }

                // F.EVENT.9 — bounds de la serie. Sólo visible cuando hay recurrencia.
                if recurrence != .none {
                    Section {
                        Picker("Hasta cuándo", selection: $seriesBound) {
                            ForEach(SeriesBound.allCases) { bound in
                                Text(bound.label).tag(bound)
                            }
                        }
                        .pickerStyle(.segmented)
                        switch seriesBound {
                        case .indefinite:
                            EmptyView()
                        case .count:
                            HStack {
                                Text("Número de ocurrencias")
                                Spacer()
                                TextField("10", text: $occurrenceCountText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Stepper("", value: occurrenceCountBinding, in: 1...365)
                                    .labelsHidden()
                            }
                        case .until:
                            DatePicker("Hasta", selection: $seriesUntil, in: startsAt..., displayedComponents: .date)
                        }
                    } header: {
                        Text("Hasta cuándo")
                    } footer: {
                        seriesBoundFooter
                    }
                }

                if !context.isPersonal {
                    Section("Invitados") {
                        Toggle("Invitar a todos los miembros", isOn: $inviteAllMembers)
                    }
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Crear evento").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Nuevo evento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func create() async {
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        // F.EVENT.9 — bounds sólo aplican si hay recurrencia.
        let count: Int? = (recurrence != .none && seriesBound == .count) ? parsedOccurrenceCount : nil
        let until: Date? = (recurrence != .none && seriesBound == .until) ? seriesUntil : nil
        let success = await runner.run {
            _ = try await store.createEvent(
                CreateEventInput(
                    contextId: context.id,
                    title: title.trimmingCharacters(in: .whitespaces),
                    eventType: eventType,
                    startsAt: startsAt,
                    locationText: isVirtual || trimmedLocation.isEmpty ? nil : trimmedLocation,
                    isVirtual: isVirtual,
                    recurrenceRule: recurrence.ruleValue,
                    recurrenceCount: count,
                    recurrenceUntil: until,
                    inviteAllMembers: inviteAllMembers,
                    clientId: UUID().uuidString
                ),
                context: context
            )
        }
        if success { dismiss() }
    }

    /// El usuario tappea una sugerencia → componemos `title, subtitle` y
    /// limpiamos las sugerencias. La bandera `suppressNextQueryUpdate` evita
    /// que el `.onChange(of:)` re-dispare el completer con el texto que
    /// acabamos de fijar.
    private func pickLocation(_ suggestion: LocationSuggestion) {
        let composed = suggestion.subtitle.isEmpty
            ? suggestion.title
            : "\(suggestion.title), \(suggestion.subtitle)"
        suppressNextQueryUpdate = true
        locationText = composed
        locationCompleter.clear()
    }
}

// MARK: - F.EVENT.7 — MKLocalSearchCompleter wrapper

/// F.EVENT.7 — wrapper observable de `MKLocalSearchCompleter`. La instancia
/// vive en un `@State` y empuja `suggestions` a la vista cuando MapKit
/// resuelve coincidencias para la dirección parcial.
///
/// `@unchecked Sendable` bypasses la verificación estática porque MapKit
/// garantiza que los delegate methods corren en el main thread (donde el
/// `@State` los lee), así que en la práctica no hay race.
@MainActor
@Observable
final class LocationCompleter: NSObject, MKLocalSearchCompleterDelegate {
    /// Hasta 5 sugerencias formateadas listas para mostrar.
    var suggestions: [LocationSuggestion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    /// Actualiza el query parcial. Texto vacío limpia las sugerencias.
    func setQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            completer.queryFragment = ""
            suggestions = []
        } else {
            completer.queryFragment = trimmed
        }
    }

    func clear() {
        completer.queryFragment = ""
        suggestions = []
    }

    // MKLocalSearchCompleterDelegate methods son nonisolated por contrato; MapKit los
    // entrega en main thread pero la firma de Apple no lleva @MainActor. Extraemos
    // strings (Sendable) y rebotamos a MainActor para escribir `suggestions`.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let snapshot: [LocationSuggestion] = completer.results.prefix(5).map {
            LocationSuggestion(title: $0.title, subtitle: $0.subtitle)
        }
        Task { @MainActor [weak self] in
            self?.suggestions = snapshot
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.suggestions = []
        }
    }
}

/// Una sugerencia de dirección renderizable por la lista.
struct LocationSuggestion: Identifiable, Hashable, Sendable {
    let id = UUID()
    let title: String
    let subtitle: String
}

#Preview("Crear evento") {
    CreateEventView(
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.cenaSemanal,
            kind: .collective,
            subtype: "friend_group",
            displayName: "Cena Semanal"
        ),
        store: EventsStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}
