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

    public init(
        resource: Resource,
        context: AppContext,
        reservationContextId: UUID? = nil,
        preselectedEventId: UUID? = nil,
        store: ReservationsStore,
        container: DependencyContainer
    ) {
        self.resource = resource
        self.context = context
        self.reservationContextId = reservationContextId ?? context.id
        self.preselectedEventId = preselectedEventId
        self.store = store
        self.container = container
    }

    public var body: some View {
        NavigationStack {
            Form {
                aiHero

                whySection

                Section("Fechas") {
                    DatePicker("Desde", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                        .onChange(of: startsAt) { _, _ in datesTouchedByUser = true }
                    DatePicker("Hasta", selection: $endsAt, in: startsAt..., displayedComponents: [.date, .hourAndMinute])
                        .onChange(of: endsAt) { _, _ in datesTouchedByUser = true }
                }

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
                    .disabled(endsAt <= startsAt || runner.isRunning)
                } footer: {
                    Text("Si las fechas se traslapan con otra solicitud, se abre un conflicto que un admin debe resolver.")
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
            }
        }
        .ruulSheet()
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
                ForEach(why.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Permisos")
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
                conflictNotice = "Tu solicitud quedó registrada, pero hay \(result.conflictsDetected) conflicto(s) de fechas. Un admin tendrá que resolverlo."
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
