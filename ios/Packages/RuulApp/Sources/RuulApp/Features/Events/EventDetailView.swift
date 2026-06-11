import SwiftUI
import RuulCore

/// F.EVENT.4 — Event Detail canonical (founder doctrine, Apple-native).
///
/// La pantalla representa una **realidad humana**, no un objeto técnico.
/// El usuario debe entender en <3 segundos: qué es, por qué le importa,
/// qué tiene que hacer, quién más participa.
///
/// Scroll order founder-locked:
/// 1. **Header** — icon inline + título + contexto tappable + fecha + chips
///    de ubicación/recurrencia + summary "N asistentes"
/// 2. **Acción principal** — zona dinámica por estado:
///    - Evento finalizado / cancelado → row gris informativo
///    - Llegada registrada → confirmación + tiempo
///    - Evento en curso → botón prominente "Llegué"
///    - Sin responder → heading "Responde tu asistencia" + segmented RSVP
///    - Ya respondí → heading "Vas a asistir" + segmented RSVP para cambiar
/// 3. **Participantes** — avatar strip + breakdown
/// 4. **Recursos relacionados** (oculta si vacío)
/// 5. **Decisiones relacionadas** (oculta si vacío)
/// 6. **Información** — Organizador / Fecha / Ubicación / Repetición / Contexto
/// 7. **Más acciones** — botón único `••• Más acciones` con Menu
///
/// Eliminado: hero icon enorme, sección Actividad reciente, sección
/// Administración visible, sección Auditoría, action strip con `•••` arriba.
///
/// Toda acción del menú sale de `event_detail.available_actions` — cero
/// hardcodes. Cuando el backend marque acciones type-specific (reservar
/// asiento para partidos, etc.), se rendereán naturalmente en el menú.
///
/// Las Sections del scroll + sheets auxiliares viven en archivos hermanos
/// `EventDetail*.swift` (split mecánico por tamaño del archivo / presupuesto
/// del type-checker). Helpers puros compartidos en `EventDetailFormatting`.
public struct EventDetailView: View {
    let eventId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: EventDetailStore
    @State private var runner = ActionRunner()
    @State private var checkInNotice: String?
    @State private var isConfirmingCancel = false
    @State private var isConfirmingClose = false
    /// Actividad del contexto filtrada a entradas que tocan este evento.
    /// Sólo se usa para derivar recursos / decisiones relacionados.
    @State private var eventActivity: [ActivityEvent] = []
    @State private var isShowingAllParticipants = false
    /// F.EVENT.6 — gasto scoped al evento.
    @State private var expenseScope: EventScope?
    @State private var moneyStoreForExpense: MoneyStore?
    @State private var pushedDecisions = false
    /// F.EVENT.7 — sheet de edición.
    @State private var isShowingEdit = false
    /// F.EVENT.8 — sheet de cambiar próximo anfitrión.
    @State private var isShowingNextHostPicker = false
    @State private var nextHostNotice: String?
    /// F.EVENT.10 — sheet de configurar el orden de rotación de host.
    @State private var isShowingRotationOrder = false
    /// R.2T — reservaciones linkeadas a este evento vía `source_event_id`.
    /// Carga ondemand una sola vez por evento (sin polling). Vacía por default.
    @State private var linkedReservations: [Reservation] = []
    /// R.2T — map `resourceId → displayName` resuelto vía `listContextResources`
    /// para mostrar nombres reales en lugar de UUIDs.
    @State private var linkedResourceNames: [UUID: String] = [:]
    /// R.2T — sheet "Reservar recurso para este evento".
    @State private var isShowingReserveResourceFlow = false

    public init(eventId: UUID, context: AppContext, container: DependencyContainer) {
        self.eventId = eventId
        self.context = context
        self.container = container
        _store = State(initialValue: EventDetailStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
    }

    /// Toolbar extraído a un computed property para no hinchar el body y
    /// evitar que el type-checker se quede sin presupuesto.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let event = store.event {
            let items = moreActions(
                event,
                availableActions: store.availableActions,
                hasManageAuthority: hasManageAuthority
            )
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // P0 fix 2026-06-08 — moreActions agrupadas por section
                        // semántica (Apple HIG: Menu con Sections para clusters).
                        ForEach(MoreActionSection.allCases, id: \.self) { section in
                            let sectionItems = items.filter { moreActionSection($0.kind) == section }
                            if !sectionItems.isEmpty {
                                Section(section.label) {
                                    ForEach(sectionItems) { item in
                                        moreActionButton(for: item)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("Más acciones")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moreActionButton(for item: MoreActionItem) -> some View {
        if item.isDestructive {
            Button(role: .destructive) {
                handleMoreAction(item.kind)
            } label: {
                Label(item.label, systemImage: item.symbol)
            }
        } else {
            Button {
                handleMoreAction(item.kind)
            } label: {
                Label(item.label, systemImage: item.symbol)
            }
        }
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }
    private var isHost: Bool { store.event?.hostActorId == myActorId }
    private var hasManageAuthority: Bool {
        guard let event = store.event else { return false }
        return event.hostActorId == myActorId || store.canManage(in: context)
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState()

            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(eventId: eventId, context: context) }
                }

            case .loaded:
                if let event = store.event {
                    detailList(event)
                }
            }
        }
        .navigationTitle(store.event?.title ?? "Evento")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            await store.load(eventId: eventId, context: context)
            await loadEventActivity()
            await loadLinkedReservations()
        }
        .refreshable {
            await store.load(eventId: eventId, context: context)
            await loadEventActivity()
            await loadLinkedReservations()
        }
        .actionErrorAlert(runner)
        .alert("Check-in registrado", isPresented: Binding(
            get: { checkInNotice != nil },
            set: { if !$0 { checkInNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(checkInNotice ?? "")
        }
        .confirmationDialog(
            "¿Cancelar tu asistencia?",
            isPresented: $isConfirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Cancelar asistencia", role: .destructive) {
                Task { await cancelParticipation() }
            }
            Button("Seguir asistiendo", role: .cancel) {}
        } message: {
            Text("Si cancelas el mismo día del evento, las reglas del contexto pueden generar una multa.")
        }
        .confirmationDialog(
            "¿Cerrar este evento?",
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Cerrar evento") {
                Task { await closeEvent() }
            }
            Button("Todavía no", role: .cancel) {}
        }
        .sheet(isPresented: $isShowingAllParticipants) {
            NavigationStack {
                ParticipantsFullView(
                    participants: store.participants,
                    store: store,
                    canCheckInOthers: hasManageAuthority && (store.event.map { EventDetailFormatting.shouldShowCheckIn($0) } ?? false),
                    onCheckIn: { participant in
                        Task { await hostCheckIn(participant) }
                    },
                    canManageRoster: isHost || hasManageAuthority,
                    myActorId: myActorId,
                    eventId: eventId,
                    rpc: container.rpc,
                    onChanged: {
                        Task { await store.load(eventId: eventId, context: context) }
                    }
                )
            }
        }
        .navigationDestination(isPresented: $pushedDecisions) {
            DecisionsListView(context: context, container: container)
        }
        // F.EVENT.6 — sheet de gasto scoped al evento.
        // R.5Z.fix.EVENT.1.2 (founder 2026-06-10 "me sale una pantalla blanca")
        // — antes el `if let moneyStore = moneyStoreForExpense` podía fallar el
        // render (sheet vacía / pantalla blanca) por race entre el @State assign
        // y la evaluación del body. Fix: construir MoneyStore inline cuando
        // todavía no existe.
        .sheet(item: $expenseScope) { scope in
            let moneyStore = moneyStoreForExpense ?? MoneyStore(
                rpc: container.rpc,
                myActorId: container.currentActorStore.actorId
            )
            RecordExpenseView(
                context: context,
                store: moneyStore,
                container: container,
                eventScope: scope
            )
        }
        // F.EVENT.7 — sheet de edición.
        .sheet(isPresented: $isShowingEdit) { editSheetContent() }
        // F.EVENT.8 — sheet picker próximo anfitrión.
        .sheet(isPresented: $isShowingNextHostPicker) { nextHostPickerSheetContent() }
        // F.EVENT.10 — sheet de configurar el orden de rotación.
        .sheet(isPresented: $isShowingRotationOrder) { hostRotationOrderSheetContent() }
        // R.2T — sheet "Reservar recurso para este evento".
        .sheet(isPresented: $isShowingReserveResourceFlow) {
            reserveResourceFlowSheet()
        }
        .alert("Próximo anfitrión", isPresented: Binding(
            get: { nextHostNotice != nil },
            set: { if !$0 { nextHostNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(nextHostNotice ?? "")
        }
    }

    @ViewBuilder
    private func editSheetContent() -> some View {
        if let event = store.event {
            EditEventView(
                event: event,
                context: context,
                container: container,
                onSaved: {
                    Task { await store.load(eventId: eventId, context: context) }
                }
            )
        }
    }

    @ViewBuilder
    private func nextHostPickerSheetContent() -> some View {
        NextHostPickerSheet(
            members: store.members.filter { $0.actorId != store.event?.hostActorId },
            currentNextHostId: store.nextHostPreview?.nextActorId,
            onPick: { actorId in
                Task { await applyNextHost(actorId) }
            }
        )
    }

    @ViewBuilder
    private func hostRotationOrderSheetContent() -> some View {
        HostRotationOrderSheet(
            members: store.members,
            currentOrder: store.event?.hostRotationOrder,
            onSave: { order in
                await saveHostRotationOrder(order)
            },
            onClear: {
                await clearHostRotationOrder()
            }
        )
    }

    /// R.2T — Sheet "Reservar recurso para este evento". Flow de 2 pasos en
    /// NavigationStack interno: ResourcePicker → RequestReservationView
    /// con `preselectedEventId` ya pasado. Al terminar, recarga
    /// `linkedReservations` para que el cambio se vea en la Section.
    @ViewBuilder
    private func reserveResourceFlowSheet() -> some View {
        ReserveResourceForEventSheet(
            event: store.event,
            eventId: eventId,
            context: context,
            container: container,
            onDone: {
                isShowingReserveResourceFlow = false
                Task { await loadLinkedReservations() }
            }
        )
    }

    // MARK: - Container (R.5V doctrina canónica — List + Section)
    //
    // Refactor 2026-06-08: ScrollView+VStack+cards manuales → List+Section
    // grouped Apple-native. "La Section ES la card." Cero `Theme.Surface.card`
    // envueltos en VStack. RuulDetailHero como primer bloque + LabeledContent
    // para info rows + NavigationLink directo en related lists.
    //
    // Cada Section vive en su propio archivo `EventDetail*Section.swift`
    // (split mecánico). El orden del scroll es founder-locked — no reordenar.

    @ViewBuilder
    private func detailList(_ event: CalendarEvent) -> some View {
        List {
            EventDetailHeroSection(event: event, context: context, store: store)
            EventDetailPrimaryActionSection(
                event: event,
                store: store,
                runner: runner,
                myActorId: myActorId,
                eventId: eventId,
                context: context,
                onSelfCheckIn: { await selfCheckIn() }
            )
            EventDetailNextSessionSection(event: event, store: store)
            EventDetailLinkedReservationsSection(
                linkedReservations: linkedReservations,
                linkedResourceNames: linkedResourceNames,
                context: context,
                container: container
            )
            EventDetailLocationSection(event: event)
            EventDetailParticipantsSection(
                store: store,
                isShowingAllParticipants: $isShowingAllParticipants
            )
            EventDetailMoneySection(
                store: store,
                onRecordExpense: { openExpenseSheet() }
            )
            EventDetailRelatedResourcesSection(
                eventActivity: eventActivity,
                context: context,
                container: container
            )
            EventDetailRelatedDecisionsSection(
                eventActivity: eventActivity,
                context: context,
                container: container
            )
            EventDetailInfoSection(event: event, context: context, store: store, isHost: isHost)
        }
        .listStyle(.insetGrouped)
    }

    private func applyNextHost(_ actorId: UUID) async {
        await runner.run {
            let result = try await store.setNextHost(eventId: eventId, actorId: actorId, context: context)
            nextHostNotice = "Próximo anfitrión actualizado: \(result.nextActorName ?? "—")."
        }
    }

    // MARK: - Más acciones (toolbar `+` top-right — ver `.toolbar` arriba)
    //
    // El catálogo (MoreActionKind / MoreActionItem / MoreActionSection /
    // moreActions builder) vive en `EventDetailMoreActions.swift`. Acá sólo
    // queda el handler porque muta @State.

    private func handleMoreAction(_ kind: MoreActionKind) {
        switch kind {
        case .recordExpense:           openExpenseSheet()
        case .createDecision:          pushedDecisions = true
        case .closeEvent:              isConfirmingClose = true
        case .cancelParticipation:     isConfirmingCancel = true
        case .editEvent:               isShowingEdit = true
        case .changeNextHost:          isShowingNextHostPicker = true
        case .configureHostRotation:   isShowingRotationOrder = true
        case .reserveResource:         isShowingReserveResourceFlow = true
        }
    }

    /// F.EVENT.10 — guarda el orden de la rotación elegido en el sheet.
    private func saveHostRotationOrder(_ order: [UUID]) async {
        await runner.run {
            try await store.setHostRotationOrder(
                eventId: eventId, actorIds: order, context: context
            )
        }
    }

    private func clearHostRotationOrder() async {
        await runner.run {
            try await store.setHostRotationOrder(
                eventId: eventId, actorIds: nil, context: context
            )
        }
    }

    /// F.EVENT.6 — el gasto desde un evento se scopea al roster del evento.
    /// MoneyStore se instancia lazy y se carga antes de presentar la sheet.
    private func openExpenseSheet() {
        guard let event = store.event else { return }
        let store = moneyStoreForExpense ?? MoneyStore(
            rpc: container.rpc,
            myActorId: container.currentActorStore.actorId
        )
        moneyStoreForExpense = store
        // R.5Z.fix.EVENT.PARTICIPANTS — el split solo aplica a participants
        // confirmados (going/checked_in). 'maybe'/'declined'/'cancelled' fuera.
        let confirmed = self.store.participants.filter { $0.countsForExpenseSplit }
        let participantIds = Set(confirmed.map(\.participantActorId))
        // R.5Z.fix.EVENT.SPLIT.WEIGHTS — calcular peso por actor:
        //   base 1 + plus_count + guest_shares (donde guest.invited_by_actor_id
        //   coincide). Si un guest fue invitado por alguien NO confirmado, ese
        //   peso se descarta (founder dropea el evento → su esposa también sale).
        var weights: [UUID: Int] = [:]
        for participant in confirmed {
            weights[participant.participantActorId] = 1 + participant.plusCount
        }
        for guest in self.store.guests where participantIds.contains(guest.invitedByActorId) {
            weights[guest.invitedByActorId, default: 1] += guest.countShare
        }
        Task {
            await store.load(context: context)
            expenseScope = EventScope(
                eventId: event.id,
                eventTitle: event.title,
                participantActorIds: participantIds,
                weights: weights
            )
        }
    }

    // MARK: - Carga + acciones

    private func loadEventActivity() async {
        do {
            let all = try await container.rpc.listActivity(
                contextId: context.id,
                limit: 200,
                before: nil,
                includeDescendants: false
            )
            eventActivity = all
                .filter { isRelatedToEvent($0) }
                .sorted { ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast) }
        } catch {
            eventActivity = []
        }
    }

    /// R.2T — carga las reservaciones que apuntan a este evento vía
    /// `source_event_id` + resuelve los display names de los recursos
    /// involucrados. Silencioso ante errores (la section simplemente no
    /// renderiza si quedó vacío).
    private func loadLinkedReservations() async {
        do {
            let reservations = try await container.rpc.listReservationsByEvent(eventId: eventId)
            linkedReservations = reservations
            guard !reservations.isEmpty else {
                linkedResourceNames = [:]
                return
            }
            let resourceIds = Set(reservations.map(\.resourceId))
            let contextResources = (try? await container.rpc.listContextResources(contextId: context.id)) ?? []
            var names: [UUID: String] = [:]
            for res in contextResources where resourceIds.contains(res.resourceId) {
                names[res.resourceId] = res.displayName
            }
            linkedResourceNames = names
        } catch {
            linkedReservations = []
            linkedResourceNames = [:]
        }
    }

    /// Una entrada de actividad está relacionada con este evento cuando:
    /// 1. Es directamente sobre el evento (subject = calendar_event eventId).
    /// 2. Algún campo del payload referencia el evento (`event_id` o
    ///    `source_event_id`).
    private func isRelatedToEvent(_ activity: ActivityEvent) -> Bool {
        if activity.subjectType == "calendar_event" && activity.subjectId == eventId {
            return true
        }
        if let payload = activity.payload {
            if payload["event_id"]?.stringValue == eventId.uuidString { return true }
            if payload["source_event_id"]?.stringValue == eventId.uuidString { return true }
        }
        return false
    }

    private func selfCheckIn() async {
        await runner.run {
            let result = try await store.checkIn(eventId: eventId, participantActorId: nil, context: context)
            checkInNotice = checkInMessage(result)
            await loadEventActivity()
        }
    }

    private func hostCheckIn(_ participant: EventParticipant) async {
        await runner.run {
            let result = try await store.checkIn(
                eventId: eventId,
                participantActorId: participant.participantActorId,
                context: context
            )
            let name = store.displayName(for: participant.participantActorId)
            checkInNotice = "\(name): " + checkInMessage(result)
            await loadEventActivity()
        }
    }

    private func checkInMessage(_ result: CheckInResult) -> String {
        if result.isLate, let minutes = result.minutesLate {
            return "Llegada tarde (\(Int(minutes)) min). Si hay regla de multa, ya se aplicó."
        }
        return "Llegada a tiempo."
    }

    private func cancelParticipation() async {
        await runner.run {
            let result = try await store.cancelParticipation(eventId: eventId, context: context)
            if result.sameDayCancellation {
                checkInNotice = "Cancelaste el mismo día del evento. Si hay regla de multa, ya se aplicó."
            }
            await loadEventActivity()
        }
    }

    private func closeEvent() async {
        await runner.run {
            let result = try await store.closeEvent(eventId: eventId, context: context)
            if let nextHost = result.nextHostActorId {
                checkInNotice = "Evento cerrado. La próxima cena ya está creada — host: \(store.displayName(for: nextHost))."
            } else if let noShows = result.noShows, noShows > 0 {
                checkInNotice = "Evento cerrado. \(noShows) no-shows registrados."
            }
            await loadEventActivity()
        }
    }
}

// MARK: - Previews

#Preview("Detalle de evento") {
    NavigationStack {
        EventDetailPreviewWrapper()
    }
}

/// El preview necesita resolver el id del evento demo de forma async.
private struct EventDetailPreviewWrapper: View {
    @State private var eventId: UUID?
    private let container = DependencyContainer.demo()
    private let context = AppContext(
        id: MockRuulRPCClient.DemoIds.cenaSemanal,
        kind: .collective,
        subtype: "friend_group",
        displayName: "Cena Semanal",
        roles: ["admin"]
    )

    var body: some View {
        Group {
            if let eventId {
                EventDetailView(eventId: eventId, context: context, container: container)
            } else {
                ProgressView()
            }
        }
        .task {
            let events = try? await container.rpc.listEvents(contextId: context.id)
            eventId = events?.first?.id
        }
    }
}
