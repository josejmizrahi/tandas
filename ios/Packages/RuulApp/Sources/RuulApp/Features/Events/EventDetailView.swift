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
            let items = moreActions(event)
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

    /// P0 fix 2026-06-08 — clasificación semántica de MoreActionKind para
    /// agrupar en el Menu toolbar.
    private enum MoreActionSection: CaseIterable {
        case registrar
        case editar
        case anfitrion
        case estado
        case cancelar

        var label: String {
            switch self {
            case .registrar: return "Registrar"
            case .editar:    return "Editar"
            case .anfitrion: return "Anfitrión"
            case .estado:    return "Estado"
            case .cancelar:  return "Cancelar"
            }
        }
    }

    private func moreActionSection(_ kind: MoreActionKind) -> MoreActionSection {
        switch kind {
        case .recordExpense, .createDecision:         return .registrar
        case .editEvent:                              return .editar
        case .changeNextHost, .configureHostRotation: return .anfitrion
        case .closeEvent:                             return .estado
        case .cancelParticipation:                    return .cancelar
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
                LoadingStateView()

            case .failed(let message):
                ErrorStateView(message: message) {
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
        }
        .refreshable {
            await store.load(eventId: eventId, context: context)
            await loadEventActivity()
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
                    canCheckInOthers: hasManageAuthority && (store.event.map { shouldShowCheckIn($0) } ?? false),
                    onCheckIn: { participant in
                        Task { await hostCheckIn(participant) }
                    }
                )
            }
        }
        .navigationDestination(isPresented: $pushedDecisions) {
            DecisionsListView(context: context, container: container)
        }
        // F.EVENT.6 — sheet de gasto scoped al evento.
        .sheet(item: $expenseScope) { scope in
            if let moneyStore = moneyStoreForExpense {
                RecordExpenseView(
                    context: context,
                    store: moneyStore,
                    container: container,
                    eventScope: scope
                )
            }
        }
        // F.EVENT.7 — sheet de edición.
        .sheet(isPresented: $isShowingEdit) { editSheetContent() }
        // F.EVENT.8 — sheet picker próximo anfitrión.
        .sheet(isPresented: $isShowingNextHostPicker) { nextHostPickerSheetContent() }
        // F.EVENT.10 — sheet de configurar el orden de rotación.
        .sheet(isPresented: $isShowingRotationOrder) { hostRotationOrderSheetContent() }
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

    // MARK: - Container (R.5V doctrina canónica — List + Section)
    //
    // Refactor 2026-06-08: ScrollView+VStack+cards manuales → List+Section
    // grouped Apple-native. "La Section ES la card." Cero `Theme.Surface.card`
    // envueltos en VStack. RuulDetailHero como primer bloque + LabeledContent
    // para info rows + NavigationLink directo en related lists.

    @ViewBuilder
    private func detailList(_ event: CalendarEvent) -> some View {
        List {
            heroSection(event)
            primaryActionSection(event)
            nextSessionSection(event)
            locationSection(event)
            participantsSection(event)
            relatedResourcesSection(event)
            relatedDecisionsSection(event)
            infoSection(event)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - F.EVENT.8 Próxima reunión (Section dedicada)

    @ViewBuilder
    private func nextSessionSection(_ event: CalendarEvent) -> some View {
        if event.isRecurring && event.isScheduled {
            if isLastSession(event) {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Última sesión de la serie")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            if let total = event.recurrenceCount {
                                Text("Sesión \(event.occurrenceNumber) de \(total). Al cerrar este evento la serie termina.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            } else if let until = event.recurrenceUntil {
                                Text("La serie termina al pasar el \(until.formatted(date: .abbreviated, time: .omitted)).")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "flag.checkered")
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
            } else if let preview = store.nextHostPreview,
                      let hostName = preview.nextActorName,
                      let nextStart = nextOccurrenceDate(for: event) {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Organiza \(hostName)")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text(nextStart.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.2.crop.square.stack.fill")
                            .foregroundStyle(Theme.Tint.primary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Próxima reunión")
                        if preview.isOverride {
                            Text("· Definido manualmente")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
        }
    }

    /// `true` cuando cerrar este evento NO va a crear una siguiente ocurrencia
    /// por alguno de los bounds (count alcanzado o next_start excede until).
    /// Espejea la lógica de `close_event` en el backend.
    private func isLastSession(_ event: CalendarEvent) -> Bool {
        if let total = event.recurrenceCount, event.occurrenceNumber >= total {
            return true
        }
        if let until = event.recurrenceUntil, let nextStart = nextOccurrenceDate(for: event),
           nextStart > until {
            return true
        }
        return false
    }

    // MARK: - F.EVENT.11 Ubicación (Section dedicada — tap → Apple Maps)

    @ViewBuilder
    private func locationSection(_ event: CalendarEvent) -> some View {
        if !event.isVirtual,
           let location = event.locationText,
           !location.isEmpty {
            Section {
                Button {
                    openLocationInMaps(location)
                } label: {
                    Label {
                        HStack {
                            Text(location)
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
            } header: {
                Text("Ubicación")
            }
        }
    }

    private func openLocationInMaps(_ location: String) {
        let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }

    /// Calcula la fecha de la próxima ocurrencia client-side a partir del
    /// `starts_at` actual + la frecuencia. El backend hace lo mismo en
    /// `close_event`; acá lo replicamos sólo para mostrar — la verdad sigue
    /// siendo del backend al cerrar.
    private func nextOccurrenceDate(for event: CalendarEvent) -> Date? {
        guard let starts = event.startsAt,
              let rule = event.recurrenceRule?.lowercased() else { return nil }
        let calendar = Calendar.current
        if rule == "weekly" || rule.contains("freq=weekly") {
            return calendar.date(byAdding: .day, value: 7, to: starts)
        }
        if rule == "daily" || rule.contains("freq=daily") {
            return calendar.date(byAdding: .day, value: 1, to: starts)
        }
        if rule == "monthly" || rule.contains("freq=monthly") {
            return calendar.date(byAdding: .month, value: 1, to: starts)
        }
        if rule == "yearly" || rule.contains("freq=yearly") {
            return calendar.date(byAdding: .year, value: 1, to: starts)
        }
        return nil
    }

    private func applyNextHost(_ actorId: UUID) async {
        await runner.run {
            let result = try await store.setNextHost(eventId: eventId, actorId: actorId, context: context)
            nextHostNotice = "Próximo anfitrión actualizado: \(result.nextActorName ?? "—")."
        }
    }

    // MARK: - 1. Hero (R.5V — RuulDetailHero canónico)

    @ViewBuilder
    private func heroSection(_ event: CalendarEvent) -> some View {
        Section {
            RuulDetailHero(
                title: event.title,
                subtitle: heroSubtitle(event),
                systemImage: event.type.symbolName,
                tint: Theme.Tint.primary,
                chips: heroChips(event)
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func heroSubtitle(_ event: CalendarEvent) -> String? {
        if let starts = event.startsAt {
            return headerDateLine(starts)
        }
        return context.displayName
    }

    /// Chips del Hero — text-only (RuulDetailHero los renderiza como pills).
    /// Ubicación, recurrencia, número de sesión, asistentes summary.
    private func heroChips(_ event: CalendarEvent) -> [String] {
        var chips: [String] = []
        if event.isVirtual {
            chips.append("Virtual")
        } else if let location = event.locationText, !location.isEmpty {
            chips.append(location)
        }
        if event.isRecurring {
            chips.append(recurrenceLabel(event))
        }
        if let total = event.recurrenceCount {
            chips.append("Sesión \(event.occurrenceNumber) de \(total)")
        }
        chips.append(participantSummary())
        return chips
    }

    private func headerDateLine(_ date: Date) -> String {
        let dayMonth = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(dayMonth.capitalizedFirstLetter) · \(time)"
    }

    /// "12 asistentes" — total de invitados al evento. Si el contexto es
    /// personal o aún no hay invitados, se ajusta.
    private func participantSummary() -> String {
        let total = store.participants.count
        if total == 0 { return "Aún sin invitados" }
        return "\(total) \(total == 1 ? "asistente" : "asistentes")"
    }

    private func recurrenceLabel(_ event: CalendarEvent) -> String {
        guard let raw = event.recurrenceRule?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return "Recurrente" }
        // F.EVENT.6 — soporta tanto los simples "weekly"/"daily"/... como
        // RRULE-style "freq=weekly"/...
        if raw == "weekly"  || raw.contains("freq=weekly")  { return "Semanal" }
        if raw == "daily"   || raw.contains("freq=daily")   { return "Diaria" }
        if raw == "monthly" || raw.contains("freq=monthly") { return "Mensual" }
        if raw == "yearly"  || raw.contains("freq=yearly")  { return "Anual" }
        return "Recurrente"
    }

    // MARK: - 2. Acción principal (zona dinámica)

    private enum PrimaryState {
        /// Evento ya no está activo (closed / cancelled).
        case ended(label: String, symbol: String, tint: Color)
        /// Hice check-in.
        case checkedIn(at: Date?)
        /// Evento en curso o por iniciar — puedo registrar llegada.
        case canCheckIn
        /// Ya respondí (going/maybe/declined) — sigue activo.
        case responded(status: String)
        /// Aún no he respondido.
        case needsResponse
    }

    private func primaryState(_ event: CalendarEvent) -> PrimaryState {
        if event.isCompleted {
            return .ended(label: "Evento finalizado", symbol: "checkmark.seal.fill", tint: .gray)
        }
        if !event.isScheduled {
            return .ended(label: "Evento cancelado", symbol: "xmark.circle.fill", tint: .red)
        }
        let mine = store.myParticipation(myActorId: myActorId)
        if mine?.checkedIn == true {
            return .checkedIn(at: mine?.checkedInAt)
        }
        if mine?.status == "cancelled" {
            return .ended(label: "Cancelaste asistencia", symbol: "xmark.circle.fill", tint: .red)
        }
        if shouldShowCheckIn(event) && mine?.status != "declined" {
            return .canCheckIn
        }
        if let status = mine?.status, ["going", "maybe", "declined"].contains(status) {
            return .responded(status: status)
        }
        return .needsResponse
    }

    @ViewBuilder
    private func primaryActionSection(_ event: CalendarEvent) -> some View {
        switch primaryState(event) {
        case .ended(let label, let symbol, let tint):
            Section {
                Label {
                    Text(label).font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
            }
        case .checkedIn(let when):
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Registraste tu llegada")
                            .font(.callout.weight(.semibold))
                        if let when {
                            Text(when.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Tint.success)
                        .symbolEffect(.bounce, value: when)
                }
            }
        case .canCheckIn:
            Section {
                Button {
                    Task { await selfCheckIn() }
                } label: {
                    Label("Llegué", systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .disabled(runner.isRunning)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
        case .needsResponse:
            rsvpSection(heading: "Responde tu asistencia", current: nil)
        case .responded(let status):
            rsvpSection(heading: respondedHeading(status), current: status)
        }
    }

    @ViewBuilder
    private func rsvpSection(heading: String, current: String?) -> some View {
        Section {
            rsvpSegmented(current: current)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
        } header: {
            Text(heading)
        } footer: {
            if let confirmation = responseConfirmation(current) {
                Text(confirmation)
            }
        }
    }

    /// Picker nativo iOS `.segmented` (UISegmentedControl). El binding es
    /// `RSVPStatus?` — cuando `current` es nil no hay segmento seleccionado.
    @ViewBuilder
    private func rsvpSegmented(current: String?) -> some View {
        let currentEnum: RSVPStatus? = current.flatMap { RSVPStatus(rawValue: $0) }
        Picker("Respuesta", selection: Binding<RSVPStatus?>(
            get: { currentEnum },
            set: { newValue in
                guard let newValue else { return }
                Task {
                    await runner.run {
                        try await store.rsvp(newValue, eventId: eventId, context: context)
                    }
                }
            }
        )) {
            Text("Voy").tag(RSVPStatus?.some(.going))
            Text("Tal vez").tag(RSVPStatus?.some(.maybe))
            Text("No voy").tag(RSVPStatus?.some(.declined))
        }
        .pickerStyle(.segmented)
        .disabled(runner.isRunning)
    }

    private func respondedHeading(_ status: String) -> String {
        switch status {
        case "going":    return "Vas a asistir"
        case "maybe":    return "Tal vez asistas"
        case "declined": return "No asistirás"
        default:         return "Tu respuesta"
        }
    }

    private func responseConfirmation(_ status: String?) -> String? {
        switch status {
        case "going":    return "Confirmaste tu asistencia."
        case "maybe":    return "Marcaste \"Tal vez\"."
        case "declined": return "No vas a este evento."
        default:         return nil
        }
    }

    /// El evento ya inició (o está por iniciar en breve).
    private func shouldShowCheckIn(_ event: CalendarEvent) -> Bool {
        guard let starts = event.startsAt else { return false }
        return Date() >= starts.addingTimeInterval(-30 * 60)
    }

    // MARK: - 3. Participantes (Section + avatar strip + breakdown)

    @ViewBuilder
    private func participantsSection(_ event: CalendarEvent) -> some View {
        if !store.participants.isEmpty {
            Section {
                Button {
                    isShowingAllParticipants = true
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        avatarStrip()
                        Text(participantBreakdown())
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Participantes (\(store.participants.count))")
            }
        }
    }

    @ViewBuilder
    private func avatarStrip() -> some View {
        let preview = Array(store.participants.prefix(5))
        let extra = store.participants.count - preview.count

        HStack(spacing: -10) {
            ForEach(preview) { participant in
                ActorInitialsView(
                    name: store.displayName(for: participant.participantActorId),
                    size: 40
                )
                .overlay(
                    Circle().strokeBorder(Theme.Surface.card, lineWidth: 3)
                )
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.badgeFill, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Theme.Surface.card, lineWidth: 3)
                    )
            }
            Spacer(minLength: 0)
        }
    }

    /// "8 confirmados · 2 tal vez · 1 no asistirá".
    private func participantBreakdown() -> String {
        let confirmed = store.participants.filter {
            $0.status == "going" || $0.status == "attended" || $0.checkedIn
        }.count
        let maybe = store.participants.filter { $0.status == "maybe" }.count
        let declined = store.participants.filter { $0.status == "declined" }.count
        let pending = store.participants.filter { $0.status == "invited" }.count

        var parts: [String] = []
        if confirmed > 0 { parts.append("\(confirmed) \(confirmed == 1 ? "confirmado" : "confirmados")") }
        if maybe > 0     { parts.append("\(maybe) tal vez") }
        if declined > 0  { parts.append("\(declined) no \(declined == 1 ? "asistirá" : "asistirán")") }
        if pending > 0 && parts.isEmpty {
            parts.append("\(pending) sin respuesta")
        }
        return parts.isEmpty ? "Sin respuestas todavía" : parts.joined(separator: " · ")
    }

    // MARK: - 4. Recursos relacionados (Section + NavigationLink nativo)

    @ViewBuilder
    private func relatedResourcesSection(_ event: CalendarEvent) -> some View {
        let items = relatedResources
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    NavigationLink {
                        ResourceDetailView(resourceId: item.id, context: context, container: container)
                    } label: {
                        Label {
                            Text(item.title)
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                        } icon: {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            } header: {
                Text("Recursos")
            }
        }
    }

    // MARK: - 5. Decisiones relacionadas (Section + NavigationLink nativo)

    @ViewBuilder
    private func relatedDecisionsSection(_ event: CalendarEvent) -> some View {
        let items = relatedDecisions
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    NavigationLink {
                        DecisionDetailView(decisionId: item.id, context: context, container: container)
                    } label: {
                        Label {
                            Text(item.title)
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.indigo)
                        }
                    }
                }
            } header: {
                Text("Decisiones")
            }
        }
    }

    private struct RelatedItem: Identifiable {
        let id: UUID
        let title: String
        let trailing: String?
    }

    /// Recursos únicos referenciados en la actividad del evento.
    private var relatedResources: [RelatedItem] {
        var seen: Set<UUID> = []
        var out: [RelatedItem] = []
        for activity in eventActivity {
            guard let id = activity.resourceId, !seen.contains(id) else { continue }
            seen.insert(id)
            let title = activity.payload?["title"]?.stringValue ?? "Recurso"
            out.append(RelatedItem(id: id, title: title, trailing: nil))
        }
        return out
    }

    /// Decisiones únicas referenciadas en la actividad del evento.
    private var relatedDecisions: [RelatedItem] {
        var seen: Set<UUID> = []
        var out: [RelatedItem] = []
        for activity in eventActivity {
            guard let id = activity.decisionId, !seen.contains(id) else { continue }
            seen.insert(id)
            let title = activity.payload?["title"]?.stringValue ?? "Decisión"
            // El status no está fácilmente disponible sin un fetch extra —
            // F.EVENT.5 puede resolverlo via decision_detail batch.
            out.append(RelatedItem(id: id, title: title, trailing: nil))
        }
        return out
    }

    // MARK: - 6. Información (LabeledContent nativo)

    @ViewBuilder
    private func infoSection(_ event: CalendarEvent) -> some View {
        Section {
            LabeledContent("Organizador") {
                Text(store.displayName(for: event.hostActorId) + (isHost ? " (tú)" : ""))
                    .foregroundStyle(Theme.Text.primary)
                    .multilineTextAlignment(.trailing)
            }
            if let starts = event.startsAt {
                LabeledContent("Fecha") {
                    Text(headerDateLine(starts))
                        .multilineTextAlignment(.trailing)
                }
            }
            if event.isVirtual {
                LabeledContent("Ubicación") {
                    Text("Virtual")
                }
            } else if let location = event.locationText, !location.isEmpty {
                LabeledContent("Ubicación") {
                    Text(location)
                        .multilineTextAlignment(.trailing)
                }
            }
            if event.isRecurring {
                LabeledContent("Repetición") {
                    Text(recurrenceLabel(event))
                }
            }
            if let total = event.recurrenceCount {
                LabeledContent("Serie") {
                    Text("\(event.occurrenceNumber) de \(total)")
                }
            }
            if let until = event.recurrenceUntil {
                LabeledContent("Termina") {
                    Text(until.formatted(date: .abbreviated, time: .omitted))
                }
            }
            LabeledContent("Contexto") {
                Text(context.displayName)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Información")
        }
    }

    // MARK: - Más acciones (toolbar `+` top-right — ver `.toolbar` arriba)

    private enum MoreActionKind {
        case recordExpense
        case createDecision
        case closeEvent
        case cancelParticipation
        case editEvent
        /// F.EVENT.8 — override del próximo anfitrión.
        case changeNextHost
        /// F.EVENT.10 — configurar el ciclo de rotación de host.
        case configureHostRotation
    }

    private struct MoreActionItem: Identifiable {
        let id = UUID()
        let kind: MoreActionKind
        let label: String
        let symbol: String
        let isDestructive: Bool
    }

    /// Las acciones del menú salen verbatim de `event_detail.available_actions`
    /// — el frontend no infiere ni hardcodea. Las acciones de participación
    /// (rsvp, check-in) NO van acá porque viven en la zona primaria arriba.
    private func moreActions(_ event: CalendarEvent) -> [MoreActionItem] {
        var out: [MoreActionItem] = []
        for action in store.availableActions where action.enabled {
            switch action.actionKey {
            case "record_expense":
                out.append(MoreActionItem(
                    kind: .recordExpense, label: action.label,
                    symbol: "dollarsign.circle", isDestructive: false
                ))
            case "create_decision":
                out.append(MoreActionItem(
                    kind: .createDecision, label: action.label,
                    symbol: "checkmark.seal", isDestructive: false
                ))
            case "close_event":
                if event.isScheduled {
                    out.append(MoreActionItem(
                        kind: .closeEvent, label: action.label,
                        symbol: "checkmark.seal", isDestructive: false
                    ))
                }
            case "cancel_participation":
                out.append(MoreActionItem(
                    kind: .cancelParticipation, label: action.label,
                    symbol: "xmark.circle", isDestructive: true
                ))
            case "edit_event":
                if event.isScheduled || event.status == "in_progress" {
                    out.append(MoreActionItem(
                        kind: .editEvent, label: action.label,
                        symbol: "pencil", isDestructive: false
                    ))
                }
            default:
                break
            }
        }
        // F.EVENT.8 — "Cambiar próximo anfitrión" sólo para eventos
        // recurrentes con autoridad de manage. No es action_key del backend
        // todavía (no se modeló en available_actions); lo derivamos del
        // estado: recurring + scheduled + hasManageAuthority.
        if event.isRecurring && event.isScheduled && hasManageAuthority {
            out.append(MoreActionItem(
                kind: .changeNextHost, label: "Cambiar próximo anfitrión",
                symbol: "person.crop.circle.badge.checkmark", isDestructive: false
            ))
            // F.EVENT.10 — sólo tiene sentido cuando la rotación natural aplica
            // (weekly). Para daily/monthly/yearly el host se mantiene, no rota.
            if recurrenceLabel(event) == "Semanal" {
                out.append(MoreActionItem(
                    kind: .configureHostRotation, label: "Configurar rotación",
                    symbol: "arrow.triangle.2.circlepath", isDestructive: false
                ))
            }
        }
        return out
    }

    private func handleMoreAction(_ kind: MoreActionKind) {
        switch kind {
        case .recordExpense:           openExpenseSheet()
        case .createDecision:          pushedDecisions = true
        case .closeEvent:              isConfirmingClose = true
        case .cancelParticipation:     isConfirmingCancel = true
        case .editEvent:               isShowingEdit = true
        case .changeNextHost:          isShowingNextHostPicker = true
        case .configureHostRotation:   isShowingRotationOrder = true
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
        let participantIds = Set(self.store.participants.map(\.participantActorId))
        Task {
            await store.load(context: context)
            expenseScope = EventScope(
                eventId: event.id,
                eventTitle: event.title,
                participantActorIds: participantIds
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

// MARK: - Sheet: ver todos los participantes (agrupados por estado)

private struct ParticipantsFullView: View {
    let participants: [EventParticipant]
    let store: EventDetailStore
    let canCheckInOthers: Bool
    let onCheckIn: (EventParticipant) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            // Agrupar por estado humano (founder doctrine).
            ForEach(groups(), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.participants) { participant in
                        HStack(spacing: 12) {
                            ActorInitialsView(name: store.displayName(for: participant.participantActorId), size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.displayName(for: participant.participantActorId))
                                Text(humanStatus(participant))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if canCheckInOthers && !participant.checkedIn
                                && participant.status != "cancelled"
                                && participant.status != "declined" {
                                Button {
                                    onCheckIn(participant)
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Participantes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
    }

    private struct ParticipantGroup {
        let title: String
        let participants: [EventParticipant]
    }

    private func groups() -> [ParticipantGroup] {
        let confirmed = participants.filter { $0.status == "going" || $0.status == "attended" || $0.checkedIn }
        let maybe = participants.filter { $0.status == "maybe" }
        let declined = participants.filter { $0.status == "declined" || $0.status == "cancelled" }
        let pending = participants.filter { $0.status == "invited" }
        let other = participants.filter { ["no_show", "late"].contains($0.status) }

        var out: [ParticipantGroup] = []
        if !confirmed.isEmpty { out.append(ParticipantGroup(title: "Confirmados", participants: confirmed)) }
        if !maybe.isEmpty     { out.append(ParticipantGroup(title: "Tal vez", participants: maybe)) }
        if !pending.isEmpty   { out.append(ParticipantGroup(title: "Sin respuesta", participants: pending)) }
        if !declined.isEmpty  { out.append(ParticipantGroup(title: "No asistirán", participants: declined)) }
        if !other.isEmpty     { out.append(ParticipantGroup(title: "Otros", participants: other)) }
        return out
    }

    private func humanStatus(_ p: EventParticipant) -> String {
        if p.checkedIn {
            if let minutes = p.minutesLate, minutes > 0 {
                return "Llegó \(Int(minutes)) min tarde"
            }
            return "Asistió"
        }
        switch p.status {
        case "going":     return "Confirmado"
        case "maybe":     return "Tal vez"
        case "declined":  return "No va"
        case "cancelled": return "Canceló"
        case "no_show":   return "No llegó"
        case "invited":   return "Sin respuesta"
        default:          return p.statusLabel
        }
    }
}

// MARK: - Helpers

private extension String {
    /// "viernes 5 de junio" → "Viernes 5 de junio" (locale es_MX usa minúscula
    /// para los días por default).
    var capitalizedFirstLetter: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
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
