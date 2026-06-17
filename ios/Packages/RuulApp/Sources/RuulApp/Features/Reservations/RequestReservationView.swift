import SwiftUI
import RuulCore

/// F.9 + R.2T (2026-06-08) — solicitar una reservación de un recurso para un
/// rango de fechas, opcionalmente linkeada a un evento via `source_event_id`.
///
/// **R.2T iOS surface (write side)**: doctrina `doctrine_r2t_reservation_vs_event`
/// permite vincular una reserva a un evento (caso Mundial: 5 partidos en el
/// Palco). El usuario elige opcionalmente "Asociar a evento" del contexto;
/// al elegir, las fechas se autopreseleccionan desde el evento. Reservation
/// NO requiere Event — el Picker tiene opción "Sin evento".
public struct RequestReservationView: View {
    let resource: Resource
    let context: AppContext
    let store: ReservationsStore
    let container: DependencyContainer
    /// Contexto donde se crea la reservación (el que gobierna el recurso).
    let reservationContextId: UUID
    /// R.2T — evento pre-seleccionado cuando se abre desde EventDetailView.
    let preselectedEventId: UUID?
    /// R.RES.POLICY.A — subtype del recurso para resolver `reservation_policy`
    /// del catalog. Opcional para back-compat (call-sites legacy sin descriptor).
    let resourceSubtypeKey: String?

    @Environment(\.dismiss) private var dismiss
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var endsAt = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var reservedForActorId: UUID?
    @State private var runner = ActionRunner()
    @State private var conflictNotice: String?
    /// R.6.AI.12 — AI hero state.
    @State private var suggestionService = ReservationSuggestionService()
    @State private var aiPromptText = ""
    @State private var lastConsidered: [RuulAIContext.Considered] = []
    /// R.2S.10 — preview de permiso (why_can_reserve).
    @State private var whyCanReserve: WhyCanReserve?
    /// R.2T — eventos del contexto disponibles para asociación.
    @State private var contextEvents: [CalendarEvent] = []
    /// R.2T — evento elegido por el usuario (nil = reserva independiente).
    @State private var sourceEventId: UUID?
    /// R.2T — controla si el usuario ya tocó las fechas manualmente, para
    /// no sobreescribirlas cuando cambia el evento elegido.
    @State private var datesTouchedByUser = false
    /// R.RES.POLICY.A — policy resolved del subtype del catalog. Si nil,
    /// behavior legacy (DatePicker date+hour, sin guidance).
    @State private var policy: ReservationPolicy?

    public init(
        resource: Resource,
        context: AppContext,
        reservationContextId: UUID? = nil,
        preselectedEventId: UUID? = nil,
        resourceSubtypeKey: String? = nil,
        store: ReservationsStore,
        container: DependencyContainer
    ) {
        self.resource = resource
        self.context = context
        self.reservationContextId = reservationContextId ?? context.id
        self.preselectedEventId = preselectedEventId
        self.resourceSubtypeKey = resourceSubtypeKey
        self.store = store
        self.container = container
    }

    public var body: some View {
        NavigationStack {
            Form {
                // R.RES.POLICY.C — hero del recurso al top (Airbnb-style).
                // El usuario ve QUÉ está reservando antes de elegir fechas.
                resourceHeroSection

                aiHero

                whySection

                // R.RES.POLICY.A — info de policy del subtype (día/hora/evento).
                policySection

                Section("Fechas") {
                    DatePicker(
                        "Desde",
                        selection: $startsAt,
                        in: dateRange,
                        displayedComponents: datePickerComponents
                    )
                    .onChange(of: startsAt) { _, _ in datesTouchedByUser = true }
                    DatePicker(
                        "Hasta",
                        selection: $endsAt,
                        in: startsAt...,
                        displayedComponents: datePickerComponents
                    )
                    .onChange(of: endsAt) { _, _ in datesTouchedByUser = true }
                }

                // R.RES.POLICY.C — resumen de la reservación (N noches/horas).
                summarySection

                eventLinkSection

                if !store.members.isEmpty {
                    Section("Para quién") {
                        Picker("Reservar para", selection: $reservedForActorId) {
                            Text("Para mí").tag(nil as UUID?)
                            ForEach(store.members) { member in
                                Text(member.displayName).tag(member.actorId as UUID?)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await request() }
                    } label: {
                        if runner.isRunning {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Solicitar reservación").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit || runner.isRunning)
                } footer: {
                    Text(submitFooter)
                }

                if let conflictNotice {
                    // R.5Z.fix.8 (founder 2026-06-09) — antes era un Label inerte
                    // que no llevaba a ningún lado. Ahora ofrece el camino directo
                    // a ResourceDetailV2 donde la conflictsCard + 3-kind dialog
                    // permite resolverlo sin cerrar el sheet.
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Conflicto de fechas detectado")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(Theme.Tint.warning)
                                Text(conflictNotice)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.Tint.warning)
                        }
                        NavigationLink {
                            ResourceDetailViewV2(resourceId: resource.id, context: context, container: container)
                        } label: {
                            Label("Ver y resolver el conflicto", systemImage: "arrow.right.circle.fill")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
            .navigationTitle("Reservar \(resource.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .actionErrorAlert(runner)
            .task {
                await loadWhy()
                await loadContextEvents()
                applyPreselectedEventIfNeeded()
                await loadPolicy()
            }
        }
        .ruulSheet()
    }

    // MARK: - R.RES.POLICY.C — Hero del recurso + resumen Airbnb-style

    @ViewBuilder
    private var resourceHeroSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: resourceSymbol)
                    .font(.title2)
                    .foregroundStyle(Theme.Tint.primary)
                    .frame(width: 44, height: 44)
                    .background(Theme.Tint.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(resource.displayName)
                        .font(.headline)
                    if let location = resource.locationText, !location.isEmpty {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let policy {
                        Text(policy.granularity.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let policy, policy.granularity != .none, endsAt > startsAt {
            Section {
                LabeledContent("Duración") {
                    Text(durationLabel(selectedDurationUnits, granularity: policy.granularity))
                        .font(.callout.weight(.medium))
                }
                if let cost = estimatedCostLabel {
                    LabeledContent("Estimado", value: cost)
                        .foregroundStyle(Theme.Tint.success)
                }
            } header: {
                Text("Resumen")
            }
        }
    }

    /// Calcula costo estimado si el recurso tiene `estimatedValue + currency`
    /// y la policy es day (asume tarifa/día = estimated_value/365) o hour
    /// (tarifa/hora = estimated_value/(365×24)). Aproximación honesta; el
    /// owner puede setear hourly_rate explícito en metadata vía R.12 fields.
    private var estimatedCostLabel: String? {
        guard let value = resource.estimatedValue, value > 0,
              let currency = resource.currency,
              let policy, policy.granularity != .none else {
            return nil
        }
        let unitsRate: Double
        switch policy.granularity {
        case .day:       unitsRate = value / 365.0
        case .hour:      unitsRate = value / (365.0 * 24.0)
        case .eventSlot: unitsRate = value
        case .none:      return nil
        }
        let total = unitsRate * Double(selectedDurationUnits)
        let formatted = total.formatted(.currency(code: currency).precision(.fractionLength(0)))
        return "\(formatted) \(currency)"
    }

    private var resourceSymbol: String {
        switch resource.resourceType {
        case "house", "primary_residence", "vacation_home", "real_estate": return "house.fill"
        case "vehicle", "car", "truck", "motorcycle":                       return "car.fill"
        case "boat":                                                       return "ferry.fill"
        case "aircraft":                                                   return "airplane"
        case "space", "office", "warehouse":                               return "building.2.fill"
        case "land":                                                       return "leaf.fill"
        default:                                                           return "shippingbox.fill"
        }
    }

    // MARK: - R.RES.POLICY.A — Policy section + UI adapt

    @ViewBuilder
    private var policySection: some View {
        if let policy {
            Section {
                LabeledContent("Unidad", value: policy.granularity.label)
                LabeledContent("Duración mínima", value: durationLabel(policy.minDurationUnits, granularity: policy.granularity))
                if let maxUnits = policy.maxDurationUnits {
                    LabeledContent("Duración máxima", value: durationLabel(maxUnits, granularity: policy.granularity))
                }
                if let days = policy.advanceWindowDays {
                    LabeledContent("Con", value: "hasta \(days) día\(days == 1 ? "" : "s") de adelanto")
                }
                LabeledContent("Aprobación", value: policy.requiresApproval ? "Requerida" : "No requerida")
            } header: {
                Text("Política de reservación")
            } footer: {
                Text(policy.requiresApproval
                     ? "Un admin del espacio debe aprobar la reserva antes de confirmarse."
                     : "La reserva queda confirmada al solicitarla si no hay conflictos.")
            }
        }
    }

    private func durationLabel(_ units: Int, granularity: ReservationPolicy.Granularity) -> String {
        switch granularity {
        case .day:       return "\(units) día\(units == 1 ? "" : "s")"
        case .hour:      return "\(units) hora\(units == 1 ? "" : "s")"
        case .eventSlot: return "Un evento"
        case .none:      return "—"
        }
    }

    /// DatePicker components según granularity: `.date` (día) vs
    /// `.date + .hourAndMinute` (hora/evento). `.none` no debería renderearse.
    private var datePickerComponents: DatePickerComponents {
        guard let policy else { return [.date, .hourAndMinute] }
        switch policy.granularity {
        case .day:                       return [.date]
        case .hour, .eventSlot, .none:   return [.date, .hourAndMinute]
        }
    }

    /// Rango válido del DatePicker: respeta `advanceWindowDays` cuando aplica.
    private var dateRange: PartialRangeFrom<Date> {
        Date()... // El min siempre es ahora; el max se controla por advance_window en validación.
    }

    /// Duración seleccionada en unidades del policy (días o horas según
    /// granularity). Usada para validar min/max.
    private var selectedDurationUnits: Int {
        let interval = endsAt.timeIntervalSince(startsAt)
        guard interval > 0 else { return 0 }
        guard let policy, policy.unitSeconds > 0 else { return 1 }
        return max(1, Int((interval / policy.unitSeconds).rounded(.up)))
    }

    /// `true` si la duración satisface min/max del policy.
    private var durationIsValid: Bool {
        guard let policy else { return endsAt > startsAt }
        if policy.granularity == .none { return false }
        let units = selectedDurationUnits
        if units < policy.minDurationUnits { return false }
        if let max = policy.maxDurationUnits, units > max { return false }
        return true
    }

    /// `true` si startsAt cae dentro de `advanceWindowDays`.
    private var advanceWindowIsValid: Bool {
        guard let policy, let days = policy.advanceWindowDays else { return true }
        let cutoff = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return startsAt <= cutoff
    }

    private var canSubmit: Bool {
        guard endsAt > startsAt else { return false }
        return durationIsValid && advanceWindowIsValid
    }

    private var submitFooter: String {
        if let policy, policy.granularity == .none {
            return "Este recurso no admite reservaciones."
        }
        if !durationIsValid, let policy {
            if selectedDurationUnits < policy.minDurationUnits {
                return "La duración mínima es \(durationLabel(policy.minDurationUnits, granularity: policy.granularity))."
            }
            if let max = policy.maxDurationUnits, selectedDurationUnits > max {
                return "La duración máxima es \(durationLabel(max, granularity: policy.granularity))."
            }
        }
        if !advanceWindowIsValid, let days = policy?.advanceWindowDays {
            return "Solo puedes reservar con hasta \(days) día\(days == 1 ? "" : "s") de adelanto."
        }
        return "Si las fechas se traslapan con otra solicitud, se abre un conflicto que un admin debe resolver."
    }

    private func loadPolicy() async {
        do {
            // R.RES.POLICY.D — primero override del resource.metadata.
            // Backend hace el mismo lookup composit (override > subtype default).
            if case .object(let metaDict) = resource.metadata,
               let overrideValue = metaDict["reservation_policy_override"],
               let decoded = decodeReservationPolicy(from: overrideValue) {
                policy = decoded
                return
            }
            // R.RES.POLICY.A — si el caller no pasa subtypeKey, resolverlo del
            // PostgREST `resources.resource_subtype_key`. Evita modificar
            // Resource Domain o list_context_resources RPC.
            let key: String?
            if let provided = resourceSubtypeKey {
                key = provided
            } else {
                key = try await container.rpc.resourceSubtypeKey(resourceId: resource.id)
            }
            guard let key else {
                policy = nil
                return
            }
            let subtypes = try await container.rpc.listResourceSubtypes(classKey: nil)
            policy = subtypes.first(where: { $0.subtypeKey == key })?.reservationPolicy
        } catch {
            // Silent: legacy behavior si no se puede cargar el catalog.
            policy = nil
        }
    }

    /// R.RES.POLICY.D — decode `reservation_policy_override` desde JSONValue.
    /// El shape es el mismo que el seed del catalog (granularity + min/max +
    /// advance + requires_approval).
    private func decodeReservationPolicy(from value: JSONValue) -> ReservationPolicy? {
        guard case .object(let dict) = value else { return nil }
        guard case .string(let granRaw) = dict["granularity"] ?? .null,
              let granularity = ReservationPolicy.Granularity(rawValue: granRaw) else {
            return nil
        }
        let minUnits: Int = {
            if case .number(let n) = dict["min_duration_units"] ?? .null { return Int(n) }
            return 1
        }()
        let maxUnits: Int? = {
            if case .number(let n) = dict["max_duration_units"] ?? .null { return Int(n) }
            return nil
        }()
        let advanceDays: Int? = {
            if case .number(let n) = dict["advance_window_days"] ?? .null { return Int(n) }
            return nil
        }()
        let requiresApproval: Bool = {
            if case .bool(let b) = dict["requires_approval"] ?? .null { return b }
            return false
        }()
        return ReservationPolicy(
            granularity: granularity,
            minDurationUnits: minUnits,
            maxDurationUnits: maxUnits,
            advanceWindowDays: advanceDays,
            requiresApproval: requiresApproval
        )
    }

    @ViewBuilder
    private var whySection: some View {
        if let why = whyCanReserve {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: why.canReserve ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(why.canReserve ? .green : .orange)
                        .imageScale(.large)
                    Text(why.canReserve ? "Puedes reservar" : "No puedes reservar")
                        .font(.callout.weight(.semibold))
                }
                // P1.14 — explicación completa del why-engine: razones del
                // backend, o fallback honesto + capability requerida si faltan.
                if why.reasons.isEmpty {
                    Text(why.canReserve
                         ? "Tienes permiso para apartar este recurso."
                         : "Necesitas que un administrador del espacio te dé permiso para reservar este recurso.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(why.reasons, id: \.self) { reason in
                        Label {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if !why.canReserve {
                    LabeledContent("Permiso necesario", value: humanCapability(why.requiredCapability))
                        .font(.caption)
                }
            } header: {
                Text("Por qué puedes (o no) reservar")
            }
        }
    }

    // MARK: - R.2T Asociar a evento (Picker opcional)

    /// Picker de eventos del contexto. Sólo aparece si hay al menos un evento
    /// activo. Caso Mundial: el usuario crea los 5 partidos primero, luego
    /// reserva el Palco para cada uno asociándolo al evento correspondiente.
    @ViewBuilder
    private var eventLinkSection: some View {
        let candidates = eventCandidates
        if !candidates.isEmpty {
            Section {
                Picker("Evento", selection: $sourceEventId) {
                    Text("Sin evento").tag(nil as UUID?)
                    ForEach(candidates) { event in
                        Text(eventPickerLabel(event)).tag(event.id as UUID?)
                    }
                }
                .onChange(of: sourceEventId) { _, newId in
                    if let event = candidates.first(where: { $0.id == newId }) {
                        applyEventDates(event)
                    }
                }
            } header: {
                Text("Asociar a evento")
            } footer: {
                if let selectedId = sourceEventId,
                   let event = candidates.first(where: { $0.id == selectedId }) {
                    Text("La reserva quedará vinculada a “\(event.title)”. Si el evento se cancela, la reserva no se cancela automáticamente.")
                } else {
                    Text("Opcional. Si esta reserva es para un evento (ej. un partido del Mundial), asóciala para verla desde el evento.")
                }
            }
        }
    }

    /// Eventos del contexto que NO estén completados/cancelados. Ordenados
    /// por fecha ascendente (los más próximos primero).
    private var eventCandidates: [CalendarEvent] {
        contextEvents
            .filter { $0.isScheduled || $0.status == "in_progress" }
            .sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
    }

    private func eventPickerLabel(_ event: CalendarEvent) -> String {
        guard let starts = event.startsAt else { return event.title }
        let date = starts.formatted(date: .abbreviated, time: .shortened)
        return "\(event.title) · \(date)"
    }

    /// Slice 7.A.5 — traduce el `required_capability` raw del backend
    /// (e.g. "USE", "MANAGE") a copy conversacional para el usuario.
    private func humanCapability(_ raw: String) -> String {
        switch raw.uppercased() {
        case "USE":         return "Permiso para usarlo"
        case "MANAGE":      return "Permiso para administrarlo"
        case "VIEW":        return "Permiso para verlo"
        case "OWN":         return "Propiedad del recurso"
        case "BENEFICIARY": return "Ser beneficiario"
        case "GOVERN":      return "Permiso de gobierno"
        default:            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Cuando el usuario elige un evento, autorrellena las fechas con las
    /// del evento — pero sólo si el usuario NO ha tocado las fechas
    /// manualmente todavía (para no sobrescribir su selección).
    private func applyEventDates(_ event: CalendarEvent) {
        guard !datesTouchedByUser,
              let starts = event.startsAt else { return }
        startsAt = starts
        if let ends = event.endsAt, ends > starts {
            endsAt = ends
        } else {
            // Si el evento no tiene endsAt, default 3 horas (típico evento social).
            endsAt = Calendar.current.date(byAdding: .hour, value: 3, to: starts) ?? starts
        }
    }

    private func loadContextEvents() async {
        contextEvents = (try? await container.rpc.listEvents(contextId: context.id)) ?? []
    }

    /// Si la sheet se abrió desde EventDetailView con un evento preseleccionado,
    /// aplicamos esa selección + sus fechas (a menos que el usuario ya las
    /// haya tocado, lo cual es imposible aquí porque acabamos de cargar).
    private func applyPreselectedEventIfNeeded() {
        guard let id = preselectedEventId,
              sourceEventId == nil,
              let event = contextEvents.first(where: { $0.id == id }) else { return }
        sourceEventId = id
        applyEventDates(event)
    }

    private func loadWhy() async {
        guard let actorId = container.currentActorStore.actorId else { return }
        whyCanReserve = try? await container.rpc.whyCanReserve(
            actorId: actorId, resourceId: resource.id
        )
    }

    private func request() async {
        let success = await runner.run {
            let result = try await store.request(
                RequestReservationInput(
                    resourceId: resource.id,
                    contextId: reservationContextId,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    reservedForActorId: reservedForActorId,
                    clientId: UUID().uuidString,
                    sourceEventId: sourceEventId
                ),
                context: context
            )
            if result.conflictsDetected > 0 {
                let conflictCount = result.conflictsDetected
                conflictNotice = "Tu solicitud quedó registrada, pero hay \(conflictCount) \(conflictCount == 1 ? "conflicto" : "conflictos") de fechas. Un admin tendrá que resolverlo\(conflictCount == 1 ? "" : "s")."
            }
        }
        if success && conflictNotice == nil {
            dismiss()
        }
    }

    // MARK: - R.6.AI.12 — AI Hero

    private var aiHero: some View {
        RuulAIHeroView(
            headline: "Pídele a Ruul",
            subtitle: "Describe la reservación y la armamos por ti",
            placeholder: "Ej: Este sábado a las 6pm",
            ctaLabel: "Pensar reservación",
            examples: [
                "Este sábado a las 6pm",
                "Del viernes al domingo",
                "Para Maria el lunes 10am",
                "Mañana de 7pm a 11pm"
            ],
            footerWhenIdle: "Descríbela con tus palabras o llena las fechas abajo.",
            footerWhenLoaded: "La reservación ya está armada. Ajusta si quieres.",
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
            contextId: reservationContextId
        )
        if case .loaded(let suggestion, let considered) = suggestionService.phase {
            applyAISuggestion(suggestion)
            lastConsidered = considered
            suggestionService.reset()
        }
    }

    private func applyAISuggestion(_ s: ReservationSuggestion) {
        if let start = EventSuggestionDateParser.parse(
            dateHint: s.startDateHint,
            timeHint: s.startTimeHint
        ) {
            startsAt = start
            datesTouchedByUser = true
        }
        // endDateHint vacío → asume mismo día por algunas horas más
        let endDateEffective = s.endDateHint.isEmpty ? s.startDateHint : s.endDateHint
        if let end = EventSuggestionDateParser.parse(
            dateHint: endDateEffective,
            timeHint: s.endTimeHint
        ) {
            // Si end <= start (e.g., usuario dijo solo "6pm" sin hora fin),
            // asume duración de 2 horas.
            if end > startsAt {
                endsAt = end
            } else {
                endsAt = startsAt.addingTimeInterval(2 * 3600)
            }
            datesTouchedByUser = true
        }
        if !s.reservedForName.isEmpty,
           let match = store.members.first(where: {
               $0.displayName.lowercased().contains(s.reservedForName.lowercased())
           }) {
            reservedForActorId = match.actorId
        }
    }
}

#Preview("Solicitar reservación") {
    RequestReservationView(
        resource: Resource(
            id: MockRuulRPCClient.DemoIds.casaValle,
            resourceType: "house",
            displayName: "Casa Valle"
        ),
        context: AppContext(
            id: MockRuulRPCClient.DemoIds.familia,
            kind: .collective,
            subtype: "family",
            displayName: "Familia Mizrahi"
        ),
        store: ReservationsStore(rpc: MockRuulRPCClient.demo()),
        container: .demo()
    )
}
