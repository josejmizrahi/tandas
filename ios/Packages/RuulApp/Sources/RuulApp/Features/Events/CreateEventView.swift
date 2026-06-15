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
    /// R.6.AI.11 — AI hero state.
    @State private var suggestionService = EventSuggestionService()
    @State private var aiPromptText = ""
    @State private var lastConsidered: [RuulAIContext.Considered] = []
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var locationText = ""
    /// R.5V.3A.event (2026-06-08) — 3 modos de ubicación:
    /// - `.physical` — dirección fija (default).
    /// - `.virtual`  — videollamada (sin ubicación física).
    /// - `.perHost`  — sólo para recurring weekly: cada anfitrión decide
    ///   semana a semana. `is_virtual=false, location_text=null`. Permite
    ///   que el host actual edite el lugar de su ocurrencia sin contaminar
    ///   las siguientes.
    @State private var locationMode: LocationMode = .physical
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
    /// R.12.F — schema + values del subtype (cargado on demand cuando cambia eventType).
    @State private var subtypeFields: [FormFieldSpec] = []
    @State private var subtypeDisplayName: String = ""
    @State private var subtypeMetadata: [String: JSONValue] = [:]

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

    /// R.5V.3A.event — 3 modos de ubicación. `.perHost` sólo está disponible
    /// para recurring semanal (la única recurrencia que rota host por doctrina
    /// F.EVENT.8). Para los demás recurrence modes, `.perHost` queda inaccesible.
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

    /// F.EVENT.5 + R.5V.3A.event — un evento debe tener ubicación física,
    /// ser virtual, O delegar al anfitrión (sólo en recurring semanal).
    private var locationIsValid: Bool {
        switch locationMode {
        case .physical: return !locationText.trimmingCharacters(in: .whitespaces).isEmpty
        case .virtual:  return true
        case .perHost:  return true
        }
    }

    /// `.perHost` siempre disponible (founder doctrina 2026-06-08: location es
    /// opcional). El label cambia según si hay rotación de host real (weekly).
    private var perHostAvailable: Bool { true }

    /// El label del 3er modo cambia según la recurrencia para ser más explícito:
    /// - weekly recurring → "Por anfitrión" (rotación real)
    /// - cualquier otra   → "Por definir" (location TBD)
    private var perHostLabel: String {
        recurrence == .weekly ? "Por anfitrión" : "Por definir"
    }

    private var perHostFooter: String {
        if recurrence == .weekly {
            return "Cada anfitrión define dónde hospeda su semana — útil para Cena Semanal o Noche de Juegos rotativa. El host actual puede editar la ubicación de su evento cuando le toque."
        }
        return "Puedes agregar la ubicación más tarde. Útil cuando todavía no decides el lugar o vives en un grupo donde rota."
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
        validationHint == nil && !runner.isRunning
    }

    /// 7.F.2 (audit 2026-06-14) — feedback inline cuando algo falta para
    /// poder crear el evento. Antes el usuario veía "Crear evento" disabled
    /// sin saber qué le faltaba (título, ubicación física, número de
    /// ocurrencias, etc.).
    private var validationHint: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Ponle un título al evento."
        }
        if locationMode == .physical && locationText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Escribe la dirección o el lugar del evento."
        }
        if recurrence != .none && seriesBound == .count && (parsedOccurrenceCount ?? 0) <= 0 {
            return "Indica cuántas ocurrencias quieres."
        }
        return nil
    }

    public var body: some View {
        NavigationStack {
            Form {
                aiHero

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

                // Ubicación va DESPUÉS de Recurrencia (founder UX 2026-06-08)
                // para que el 3er modo se renombre dinámicamente:
                // weekly → "Por anfitrión", otras → "Por definir".
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
                        Text("Sin ubicación física. Después puedes compartir el link del Zoom o Meet.")
                    case .perHost:
                        Text(perHostFooter)
                    }
                }

                if !context.isPersonal {
                    Section("Invitados") {
                        Toggle("Invitar a todos los miembros", isOn: $inviteAllMembers)
                    }
                }

                // R.12.F — campos específicos del subtype (dinner.dress_code/
                // menu_summary, meeting.agenda, etc). Se cargan del catalog
                // `resource_subtypes` matching eventType.rawValue.
                if !subtypeFields.isEmpty {
                    Section {
                        DynamicForm(
                            schema: FormSchema(fields: subtypeFields),
                            values: $subtypeMetadata
                        )
                    } header: {
                        Text("Detalles \(subtypeDisplayName.lowercased())")
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
                } footer: {
                    // 7.F.2 — hint inline cuando el botón está disabled.
                    if let validationHint {
                        Label(validationHint, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.Tint.warning)
                    }
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
            .task(id: eventType.rawValue) { await loadSubtypeFields() }
        }
        .ruulSheet()
    }

    /// R.12.F — carga el subtype del catalog matching `eventType.rawValue`
    /// (dinner/meeting/community_event/recurring_event en `resource_subtypes`
    /// con class_key='event'). Si el subtype tiene fields, aparece la section
    /// "Detalles <tipo>". Reset de values al cambiar tipo.
    private func loadSubtypeFields() async {
        subtypeMetadata = [:]
        do {
            let all = try await container.rpc.listResourceSubtypes(classKey: "event")
            if let match = all.first(where: { $0.subtypeKey == eventType.rawValue }) {
                subtypeFields = match.fields
                subtypeDisplayName = match.displayName
            } else {
                subtypeFields = []
                subtypeDisplayName = ""
            }
        } catch {
            subtypeFields = []
            subtypeDisplayName = ""
        }
    }

    private func create() async {
        let trimmedLocation = locationText.trimmingCharacters(in: .whitespaces)
        // F.EVENT.9 — bounds sólo aplican si hay recurrencia.
        let count: Int? = (recurrence != .none && seriesBound == .count) ? parsedOccurrenceCount : nil
        let until: Date? = (recurrence != .none && seriesBound == .until) ? seriesUntil : nil
        // R.5V.3A.event — payload por mode:
        // - physical: location_text=texto, is_virtual=false
        // - virtual:  location_text=nil,    is_virtual=true
        // - perHost:  location_text=nil,    is_virtual=false (host decide después)
        let payloadLocation: String? = locationMode == .physical && !trimmedLocation.isEmpty
            ? trimmedLocation
            : nil
        let payloadVirtual: Bool = locationMode == .virtual
        let metadataPayload: JSONValue? = subtypeMetadata.isEmpty ? nil : .object(subtypeMetadata)
        let success = await runner.run {
            _ = try await store.createEvent(
                CreateEventInput(
                    contextId: context.id,
                    title: title.trimmingCharacters(in: .whitespaces),
                    eventType: eventType,
                    startsAt: startsAt,
                    locationText: payloadLocation,
                    isVirtual: payloadVirtual,
                    recurrenceRule: recurrence.ruleValue,
                    recurrenceCount: count,
                    recurrenceUntil: until,
                    inviteAllMembers: inviteAllMembers,
                    clientId: UUID().uuidString,
                    metadata: metadataPayload
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

    // MARK: - R.6.AI.11 — AI Hero

    private var aiHero: some View {
        RuulAIHeroView(
            headline: "Pídele a Ruul",
            subtitle: "Describe el evento y lo armamos por ti",
            placeholder: "Ej: Cena el viernes 8pm en casa de Maria",
            ctaLabel: "Pensar evento",
            examples: [
                "Cena el viernes 8pm en casa de Maria",
                "Reunión el lunes a las 10am",
                "Noche de juegos el sábado",
                "Cumpleaños de Aaron el 15 a las 7pm"
            ],
            footerWhenIdle: "Descríbelo con tus palabras o llena los campos abajo.",
            footerWhenLoaded: "El evento ya está armado. Ajusta lo que necesites y crea.",
            prompt: $aiPromptText,
            considered: $lastConsidered,
            phase: aiPhase,
            onSuggest: { await aiSuggest() },
            onReset: {
                lastConsidered = []
                aiPromptText = ""
                suggestionService.reset()
            }
        )
    }

    private var aiPhase: RuulAIHeroView.HeroPhase {
        switch suggestionService.phase {
        case .idle, .loaded: return .idle
        case .loading:       return .loading
        case .failed(let m): return .failed(message: m)
        case .unavailable(let r): return .unavailable(reason: r)
        }
    }

    private func aiSuggest() async {
        await suggestionService.suggest(
            prompt: aiPromptText,
            rpc: container.rpc,
            contextId: context.id
        )
        if case .loaded(let suggestion, let considered) = suggestionService.phase {
            applyAISuggestion(suggestion)
            lastConsidered = considered
            suggestionService.reset()
        }
    }

    private func applyAISuggestion(_ s: EventSuggestion) {
        if !s.title.isEmpty { title = s.title }
        if let mapped = EventType(rawValue: s.eventTypeKey) {
            eventType = mapped
        }
        if let parsedDate = EventSuggestionDateParser.parse(
            dateHint: s.dateHint,
            timeHint: s.timeHint
        ) {
            startsAt = parsedDate
        }
        if !s.locationText.isEmpty {
            // F.EVENT.7 — suprime el siguiente onChange del completer así
            // no abre la lista de resultados sugeridos automáticamente.
            suppressNextQueryUpdate = true
            locationText = s.locationText
        }
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
