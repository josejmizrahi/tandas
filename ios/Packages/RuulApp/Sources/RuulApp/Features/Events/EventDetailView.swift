import SwiftUI
import RuulCore

/// F.EVENT.1 — Event Detail Apple-native.
///
/// El usuario no abre un evento para administrar metadata: lo abre para
/// participar, coordinar y seguir lo que pasa. La pantalla se siente más
/// como Apple Calendar / Wallet Event Pass que como un ERP.
///
/// Jerarquía founder-locked:
/// 1. Hero (icon + título + fecha grande + organiza · resumen · ubicación · recurrencia)
/// 2. Mi respuesta (segmented Voy / Tal vez / No voy)
/// 3. Check-in (botón prominente cuando ya inició)
/// 4. Participantes (avatares + estado humano, máx 5 + Ver todos)
/// 5. Relacionado con este evento (Gastos · Decisiones · Documentos · Reservaciones)
/// 6. Actividad reciente (timeline humano, máx 5)
/// 7. Administración (DisclosureGroup, sólo host/manage)
/// 8. Auditoría (DisclosureGroup, sólo manage)
///
/// Cero exposición de claves técnicas (`event.checkin_created`, `decision.vote_cast`).
/// Las acciones intent-first del backend siguen siendo la única fuente — sólo
/// que se redistribuyen: participación (rsvp/check-in/cancel) sube al hero,
/// administración baja al final.
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
    @State private var eventActivity: [ActivityEvent] = []
    @State private var isShowingAllParticipants = false
    @State private var isShowingFullActivity = false
    @State private var relatedBucket: RelatedBucket?
    @State private var adminAction: AdminAction?

    public init(eventId: UUID, context: AppContext, container: DependencyContainer) {
        self.eventId = eventId
        self.context = context
        self.container = container
        _store = State(initialValue: EventDetailStore(rpc: container.rpc, myActorId: container.currentActorStore.actorId))
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
                    detailScroll(event)
                }
            }
        }
        .navigationTitle(store.event?.title ?? "Evento")
        .navigationBarTitleDisplayMode(.inline)
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
                    canCheckInOthers: hasManageAuthority,
                    onCheckIn: { participant in
                        Task { await hostCheckIn(participant) }
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingFullActivity) {
            NavigationStack {
                EventActivityFullView(events: eventActivity, container: container)
            }
        }
        .navigationDestination(item: $relatedBucket) { bucket in
            switch bucket {
            case .money:        MoneyHomeView(context: context, container: container)
            case .decisions:    DecisionsListView(context: context, container: container)
            case .documents, .reservations:
                // Sin lista filtrable por evento todavía — la fila no es tappable
                // pero el navigationDestination necesita cubrir todos los casos.
                EmptyView()
            }
        }
        .navigationDestination(item: $adminAction) { action in
            switch action {
            case .recordExpense: MoneyHomeView(context: context, container: container)
            case .createDecision: DecisionsListView(context: context, container: container)
            }
        }
    }

    // MARK: - Container

    @ViewBuilder
    private func detailScroll(_ event: CalendarEvent) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                heroSection(event)
                myResponseSection(event)
                checkInSection(event)
                participantsSection(event)
                relatedSection(event)
                activitySection(event)
                adminSection(event)
                auditSection(event)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    // MARK: - 1. Hero

    @ViewBuilder
    private func heroSection(_ event: CalendarEvent) -> some View {
        VStack(spacing: 14) {
            Image(systemName: event.type.symbolName)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(width: 80, height: 80)
                .background(Color.accentColor.opacity(0.15), in: Circle())

            Text(event.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            if let starts = event.startsAt {
                VStack(spacing: 2) {
                    Text(starts.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(starts.formatted(date: .omitted, time: .shortened))
                        .font(.title3.weight(.semibold))
                }
            }

            VStack(spacing: 6) {
                Text(organizerLine(event))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(participantSummary(event))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }

            if event.locationText?.isEmpty == false || event.isRecurring || !event.isScheduled {
                HStack(spacing: 8) {
                    if let location = event.locationText, !location.isEmpty {
                        heroChip(symbol: "mappin.and.ellipse", text: location)
                    }
                    if event.isRecurring {
                        heroChip(symbol: "arrow.triangle.2.circlepath", text: recurrenceLabel(event))
                    }
                    if !event.isScheduled {
                        heroChip(
                            symbol: event.isCompleted ? "checkmark.seal" : "xmark.circle",
                            text: event.isCompleted ? "Cerrado" : "Cancelado",
                            tint: event.isCompleted ? .gray : .red
                        )
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func heroChip(symbol: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private func organizerLine(_ event: CalendarEvent) -> String {
        let name = store.displayName(for: event.hostActorId)
        if isHost { return "Organizas tú" }
        return "Organiza \(name)"
    }

    private func participantSummary(_ event: CalendarEvent) -> String {
        let total = store.participants.count
        let confirmed = store.participants.filter {
            $0.status == "going" || $0.status == "attended" || $0.checkedIn
        }.count
        let pending = store.participants.filter {
            $0.status == "invited" || $0.status == "maybe"
        }.count

        if total == 0 { return "Aún sin invitados" }
        if confirmed > 0 && pending > 0 {
            return "\(confirmed) confirmados · \(pending) pendientes"
        }
        if confirmed > 0 {
            return "\(confirmed) \(confirmed == 1 ? "confirmado" : "confirmados")"
        }
        return "\(total) \(total == 1 ? "invitado" : "invitados")"
    }

    /// Traducción humana del campo `recurrence_rule` (RRULE simplificado).
    private func recurrenceLabel(_ event: CalendarEvent) -> String {
        guard let rule = event.recurrenceRule?.uppercased() else { return "Recurrente" }
        if rule.contains("FREQ=WEEKLY") { return "Semanal" }
        if rule.contains("FREQ=DAILY")  { return "Diario" }
        if rule.contains("FREQ=MONTHLY") { return "Mensual" }
        if rule.contains("FREQ=YEARLY") { return "Anual" }
        return "Recurrente"
    }

    // MARK: - 2. Mi respuesta

    private func myResponseSection(_ event: CalendarEvent) -> some View {
        let mine = store.myParticipation(myActorId: myActorId)
        // Si ya hizo check-in o canceló, su respuesta está cerrada y se
        // refleja en el check-in/participantes.
        let canRespond = event.isScheduled && mine?.checkedIn != true && mine?.status != "cancelled"
        guard canRespond else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                Text("Tu respuesta")
                    .font(.title3.weight(.semibold))

                HStack(spacing: 8) {
                    responseChip("Voy", status: .going, current: mine?.status)
                    responseChip("Tal vez", status: .maybe, current: mine?.status)
                    responseChip("No voy", status: .declined, current: mine?.status)
                }

                if let current = mine?.status, current == "going" || current == "maybe" || current == "declined" {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                        Text(responseConfirmation(current))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func responseChip(_ label: String, status: RSVPStatus, current: String?) -> some View {
        let isCurrent = current == status.rawValue
        Button {
            Task {
                await runner.run {
                    try await store.rsvp(status, eventId: eventId, context: context)
                }
            }
        } label: {
            Text(label)
                .font(.callout.weight(isCurrent ? .bold : .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    isCurrent ? Color.accentColor.opacity(0.20) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(runner.isRunning)
    }

    private func responseConfirmation(_ status: String) -> String {
        switch status {
        case "going":    return "Vas a este evento"
        case "maybe":    return "Tal vez vayas"
        case "declined": return "No vas a este evento"
        default:         return "Respuesta registrada"
        }
    }

    // MARK: - 3. Check-in

    private func checkInSection(_ event: CalendarEvent) -> some View {
        guard event.isScheduled, shouldShowCheckIn(event) else { return AnyView(EmptyView()) }
        let mine = store.myParticipation(myActorId: myActorId)

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                if mine?.checkedIn == true {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Llegada registrada")
                                .font(.callout.weight(.semibold))
                            if let when = mine?.checkedInAt {
                                Text(when.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                } else if mine?.status != "declined" {
                    Button {
                        Task { await selfCheckIn() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Hacer check-in")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(runner.isRunning)
                }
            }
        )
    }

    /// El evento ya inició (o está por iniciar en breve).
    private func shouldShowCheckIn(_ event: CalendarEvent) -> Bool {
        guard let starts = event.startsAt else { return false }
        // 30 min antes ya consideramos que se puede hacer check-in.
        return Date() >= starts.addingTimeInterval(-30 * 60)
    }

    // MARK: - 4. Participantes

    @ViewBuilder
    private func participantsSection(_ event: CalendarEvent) -> some View {
        if store.participants.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Participantes (\(store.participants.count))")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if store.participants.count > 5 {
                        Button("Ver todos →") {
                            isShowingAllParticipants = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                }

                VStack(spacing: 0) {
                    let preview = Array(store.participants.prefix(5))
                    ForEach(Array(preview.enumerated()), id: \.offset) { idx, participant in
                        participantRow(participant, event: event)
                        if idx < preview.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private func participantRow(_ participant: EventParticipant, event: CalendarEvent) -> some View {
        let name = store.displayName(for: participant.participantActorId)
        let canCheckIn = hasManageAuthority && shouldShowCheckIn(event)
            && !participant.checkedIn
            && participant.status != "cancelled"
            && participant.status != "declined"

        HStack(spacing: 12) {
            ActorInitialsView(name: name, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout)
                Text(humanParticipantStatus(participant))
                    .font(.caption)
                    .foregroundStyle(participantStatusColor(participant.status))
            }
            Spacer()
            if canCheckIn {
                Button {
                    Task { await hostCheckIn(participant) }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(runner.isRunning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Traducción humana del estado de un participante (sin badges técnicos).
    private func humanParticipantStatus(_ p: EventParticipant) -> String {
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
        case "attended":  return "Asistió"
        case "late":      return "Llegó tarde"
        case "invited":   return "Sin respuesta"
        default:          return p.statusLabel
        }
    }

    // MARK: - 5. Relacionado con este evento

    @ViewBuilder
    private func relatedSection(_ event: CalendarEvent) -> some View {
        let buckets = relatedBuckets()
        if buckets.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Relacionado con este evento")
                    .font(.title3.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { idx, item in
                        Button {
                            navigateToBucket(item.bucket)
                        } label: {
                            relatedRow(item)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.bucket.destination == nil)
                        if idx < buckets.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private func relatedRow(_ item: RelatedItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.bucket.symbol)
                .font(.callout)
                .foregroundStyle(item.bucket.tint)
                .frame(width: 32, height: 32)
                .background(item.bucket.tint.opacity(0.12), in: Circle())
            Text(item.bucket.title)
                .font(.callout)
            Spacer()
            Text("\(item.count)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            if item.bucket.destination != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func navigateToBucket(_ bucket: RelatedBucket) {
        if bucket.destination != nil {
            relatedBucket = bucket
        }
    }

    private func relatedBuckets() -> [RelatedItem] {
        var counts: [RelatedBucket: Int] = [:]
        for ev in eventActivity {
            switch ev.domain {
            case "expense", "fine", "split", "settlement", "game_result":
                counts[.money, default: 0] += 1
            case "decision":
                counts[.decisions, default: 0] += 1
            case "document":
                counts[.documents, default: 0] += 1
            case "reservation":
                counts[.reservations, default: 0] += 1
            default:
                break
            }
        }
        // Orden fijo: dinero → decisiones → documentos → reservaciones.
        let order: [RelatedBucket] = [.money, .decisions, .documents, .reservations]
        return order.compactMap { bucket in
            guard let count = counts[bucket], count > 0 else { return nil }
            return RelatedItem(bucket: bucket, count: count)
        }
    }

    // MARK: - 6. Actividad reciente

    @ViewBuilder
    private func activitySection(_ event: CalendarEvent) -> some View {
        if eventActivity.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Actividad reciente")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if eventActivity.count > 5 {
                        Button("Ver todo →") {
                            isShowingFullActivity = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                }
                VStack(spacing: 0) {
                    let preview = Array(eventActivity.prefix(5))
                    ForEach(Array(preview.enumerated()), id: \.offset) { idx, activity in
                        activityRow(activity)
                        if idx < preview.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: activity.symbolName)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(humanActivityTitle(activity))
                    .font(.callout)
                    .lineLimit(2)
                if let occurred = activity.occurredAt {
                    Text(occurred.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Traducción a lenguaje humano (con el nombre del actor cuando se conoce),
    /// nunca expone `event_type` técnico. Usa el `friendlyTitle` del dominio
    /// + el actor name resuelto por el store.
    private func humanActivityTitle(_ activity: ActivityEvent) -> String {
        let actor = activity.actorId == myActorId
            ? "Tú"
            : store.displayName(for: activity.actorId)
        let body = activity.friendlyTitle(currentActorId: myActorId)
        // El actor es opcional (system events no tienen actor humano).
        if activity.isSystemGenerated || activity.actorId == nil { return body }
        return "\(actor): \(body)"
    }

    // MARK: - 7. Administración

    @ViewBuilder
    private func adminSection(_ event: CalendarEvent) -> some View {
        let actions = adminActions(event)
        if hasManageAuthority && !actions.isEmpty {
            VStack(spacing: 0) {
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { idx, action in
                            Button {
                                handleAdminAction(action)
                            } label: {
                                adminRow(action)
                            }
                            .buttonStyle(.plain)
                            .disabled(runner.isRunning)
                            if idx < actions.count - 1 {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Administración", systemImage: "gearshape")
                        .font(.callout.weight(.semibold))
                }
                .padding(16)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func adminRow(_ action: AdminActionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: action.symbol)
                .font(.callout)
                .foregroundStyle(action.tint)
                .frame(width: 22)
            Text(action.label)
                .font(.callout)
                .foregroundStyle(action.role == .destructive ? Color.red : Color.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Las acciones que aparecen acá son las que el backend marca como
    /// `enabled` en `event_detail.available_actions` y que NO son acciones de
    /// participación (rsvp/check-in/cancel — esas viven arriba). Cerrar evento
    /// se agrega manualmente como acción de host cuando hay autoridad.
    private func adminActions(_ event: CalendarEvent) -> [AdminActionItem] {
        var out: [AdminActionItem] = []

        for action in store.availableActions where action.enabled {
            switch action.actionKey {
            case "record_expense":
                out.append(AdminActionItem(
                    kind: .recordExpense, label: action.label,
                    symbol: "dollarsign.circle.fill", tint: .green
                ))
            case "create_decision":
                out.append(AdminActionItem(
                    kind: .createDecision, label: action.label,
                    symbol: "checkmark.seal.fill", tint: .indigo
                ))
            case "attach_document":
                // F.EVENT.1 — aún no hay sheet de adjuntar documento al evento
                // (sólo a recurso). Lo omitimos hasta que el backend lo soporte.
                break
            case "close_event":
                if event.isScheduled {
                    out.append(AdminActionItem(
                        kind: .closeEvent, label: action.label,
                        symbol: "checkmark.seal", tint: .gray, role: .destructive
                    ))
                }
            default:
                break
            }
        }

        return out
    }

    private func handleAdminAction(_ action: AdminActionItem) {
        switch action.kind {
        case .recordExpense:   adminAction = .recordExpense
        case .createDecision:  adminAction = .createDecision
        case .closeEvent:      isConfirmingClose = true
        }
    }

    // MARK: - 8. Auditoría

    @ViewBuilder
    private func auditSection(_ event: CalendarEvent) -> some View {
        if !hasManageAuthority { EmptyView() } else {
            VStack(spacing: 0) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        if let created = event.createdAt {
                            auditRow(label: "Creado", value: created.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let by = event.createdByActorId {
                            auditRow(label: "Creado por", value: store.displayName(for: by))
                        }
                        if let tz = event.timezone, !tz.isEmpty {
                            auditRow(label: "Zona horaria", value: tz)
                        }
                        if let rule = event.recurrenceRule, !rule.isEmpty {
                            auditRow(label: "Recurrencia", value: rule)
                        }
                        auditRow(label: "Estado", value: event.status)
                        auditRow(label: "ID", value: event.id.uuidString, monospaced: true)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Auditoría", systemImage: "doc.text.magnifyingglass")
                        .font(.callout.weight(.semibold))
                }
                .padding(16)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func auditRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
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
    /// 1. Es directamente sobre el evento (`subject_type = calendar_event` +
    ///    `subject_id = eventId`).
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

    private func participantStatusColor(_ status: String) -> Color {
        switch status {
        case "going", "attended": return .green
        case "late":              return .orange
        case "maybe":             return .blue
        case "declined", "cancelled", "no_show": return .red
        case "invited":           return .secondary
        default:                  return .secondary
        }
    }
}

// MARK: - Tipos de soporte

/// Buckets de "Relacionado con este evento". Hashable porque
/// `navigationDestination(item:)` lo requiere.
private enum RelatedBucket: String, Hashable, Identifiable {
    case money
    case decisions
    case documents
    case reservations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .money:        return "Gastos"
        case .decisions:    return "Decisiones"
        case .documents:    return "Documentos"
        case .reservations: return "Reservaciones"
        }
    }

    var symbol: String {
        switch self {
        case .money:        return "dollarsign.circle.fill"
        case .decisions:    return "checkmark.seal.fill"
        case .documents:    return "doc.fill"
        case .reservations: return "calendar.badge.clock"
        }
    }

    var tint: Color {
        switch self {
        case .money:        return .green
        case .decisions:    return .indigo
        case .documents:    return .blue
        case .reservations: return .orange
        }
    }

    /// `nil` cuando no hay todavía una lista filtrable por evento.
    /// Cuando sea no-nil, la fila se vuelve tappable y empuja la lista
    /// del feature al contexto actual.
    var destination: Bool? {
        switch self {
        case .money, .decisions: return true
        case .documents, .reservations: return nil
        }
    }
}

private struct RelatedItem: Identifiable {
    let bucket: RelatedBucket
    let count: Int
    var id: String { bucket.id }
}

/// Tipos de acción admin que aparecen en la sección "Administración".
private enum AdminAction: String, Hashable, Identifiable {
    case recordExpense
    case createDecision
    var id: String { rawValue }
}

/// Una fila de admin renderizable: kind dirige el routing, label/symbol/tint
/// vienen del catálogo o del backend.
private struct AdminActionItem {
    enum Kind { case recordExpense, createDecision, closeEvent }
    enum Role { case standard, destructive }
    let kind: Kind
    let label: String
    let symbol: String
    let tint: Color
    var role: Role = .standard
}

// MARK: - Sheet: ver todos los participantes

private struct ParticipantsFullView: View {
    let participants: [EventParticipant]
    let store: EventDetailStore
    let canCheckInOthers: Bool
    let onCheckIn: (EventParticipant) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(participants) { participant in
                HStack(spacing: 12) {
                    ActorInitialsView(name: store.displayName(for: participant.participantActorId), size: 36)
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
        .navigationTitle("Participantes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
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

// MARK: - Sheet: actividad completa del evento

private struct EventActivityFullView: View {
    let events: [ActivityEvent]
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.symbolName)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.friendlyTitle(currentActorId: container.currentActorStore.actorId))
                            .font(.callout)
                        if let occurred = event.occurredAt {
                            Text(occurred.formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .navigationTitle("Actividad del evento")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
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
