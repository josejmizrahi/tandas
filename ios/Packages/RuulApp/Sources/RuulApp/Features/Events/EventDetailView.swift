import SwiftUI
import RuulCore

/// F.EVENT.2 — Event Detail Apple-native (Calendar / Reminders / Invites style).
///
/// El evento es algo a lo que asistes, no algo que administras. La pantalla
/// se optimiza para responder asistencia, ver quién va y entender qué pasa.
/// Todo lo administrativo (cerrar, registrar gasto, abrir decisión, adjuntar
/// documento, cancelar mi asistencia) vive detrás de `•••` en el toolbar.
///
/// Scroll order founder-locked:
/// 1. Header compacto (icon inline + título + fecha + resumen)
/// 2. Tu respuesta (chips grandes Voy / Tal vez / No voy)
/// 3. Participantes (avatares horizontales + summary)
/// 4. Información (Organizador / Ubicación / Repetición / Contexto)
/// 5. Check-in (sólo si aplica y no se ha hecho)
/// 6. Recursos relacionados (sólo si hay)
/// 7. Decisiones relacionadas (sólo si hay)
///
/// Eliminado vs F.EVENT.1:
/// - Hero icon enorme
/// - Sección Actividad reciente
/// - Sección Administración
/// - Sección Auditoría
/// - Sección Relacionado con counts/buckets
///
/// Toda acción visible sale de `event_detail.available_actions`. Las
/// administrativas se filtran al menú `•••`.
public struct EventDetailView: View {
    let eventId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: EventDetailStore
    @State private var runner = ActionRunner()
    @State private var checkInNotice: String?
    @State private var isConfirmingCancel = false
    @State private var isConfirmingClose = false
    /// Actividad del contexto, filtrada a entradas que tocan este evento.
    /// Sólo se usa para derivar recursos/decisiones relacionados — la sección
    /// "Actividad reciente" fue eliminada en F.EVENT.2.
    @State private var eventActivity: [ActivityEvent] = []
    @State private var isShowingAllParticipants = false
    @State private var pushedResource: UUID?
    @State private var pushedDecision: UUID?
    @State private var pushedMoney = false
    @State private var pushedDecisions = false

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
        .toolbar {
            if let event = store.event, !moreActions(event).isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    moreMenu(event)
                }
            }
        }
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
        .navigationDestination(item: $pushedResource) { resourceId in
            ResourceDetailView(resourceId: resourceId, context: context, container: container)
        }
        .navigationDestination(item: $pushedDecision) { decisionId in
            DecisionDetailView(decisionId: decisionId, context: context, container: container)
        }
        .navigationDestination(isPresented: $pushedMoney) {
            MoneyHomeView(context: context, container: container)
        }
        .navigationDestination(isPresented: $pushedDecisions) {
            DecisionsListView(context: context, container: container)
        }
    }

    // MARK: - Container

    @ViewBuilder
    private func detailScroll(_ event: CalendarEvent) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCompact(event)
                responseSection(event)
                participantsSection(event)
                infoSection(event)
                checkInSection(event)
                relatedResourcesSection(event)
                relatedDecisionsSection(event)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    // MARK: - 1. Header compacto

    @ViewBuilder
    private func headerCompact(_ event: CalendarEvent) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: event.type.symbolName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(event.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let starts = event.startsAt {
                Text(headerDateLine(starts))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(participantSummary())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !event.isScheduled {
                HStack(spacing: 6) {
                    Image(systemName: event.isCompleted ? "checkmark.seal" : "xmark.circle")
                    Text(event.isCompleted ? "Cerrado" : "Cancelado")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(event.isCompleted ? Color.gray : Color.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .padding(.top, 8)
    }

    private func headerDateLine(_ date: Date) -> String {
        let dayMonth = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(dayMonth.capitalizedFirstLetter) · \(time)"
    }

    private func participantSummary() -> String {
        let total = store.participants.count
        let confirmed = store.participants.filter {
            $0.status == "going" || $0.status == "attended" || $0.checkedIn
        }.count
        if total == 0 { return "Aún sin invitados" }
        if confirmed > 0 { return "\(confirmed) \(confirmed == 1 ? "confirmado" : "confirmados")" }
        return "\(total) \(total == 1 ? "invitado" : "invitados")"
    }

    // MARK: - 2. Tu respuesta

    private func responseSection(_ event: CalendarEvent) -> some View {
        let mine = store.myParticipation(myActorId: myActorId)
        let canRespond = event.isScheduled && mine?.checkedIn != true && mine?.status != "cancelled"
        guard canRespond else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                Text("Tu respuesta")
                    .font(.title3.weight(.semibold))

                HStack(spacing: 10) {
                    responseChip("Voy", icon: "checkmark.circle.fill", status: .going, current: mine?.status)
                    responseChip("Tal vez", icon: "questionmark.circle.fill", status: .maybe, current: mine?.status)
                    responseChip("No voy", icon: "xmark.circle.fill", status: .declined, current: mine?.status)
                }

                if let confirmation = responseConfirmation(mine?.status) {
                    Text(confirmation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        )
    }

    @ViewBuilder
    private func responseChip(_ label: String, icon: String, status: RSVPStatus, current: String?) -> some View {
        let isCurrent = current == status.rawValue
        Button {
            Task {
                await runner.run {
                    try await store.rsvp(status, eventId: eventId, context: context)
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                Text(label)
                    .font(.callout.weight(isCurrent ? .bold : .semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isCurrent ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(runner.isRunning)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }

    private func responseConfirmation(_ status: String?) -> String? {
        switch status {
        case "going":    return "Confirmaste tu asistencia."
        case "maybe":    return "Marcaste \"Tal vez\"."
        case "declined": return "No asistirás."
        default:         return nil
        }
    }

    // MARK: - 3. Participantes (horizontal avatars + summary)

    @ViewBuilder
    private func participantsSection(_ event: CalendarEvent) -> some View {
        if store.participants.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Participantes")
                    .font(.title3.weight(.semibold))

                Button {
                    isShowingAllParticipants = true
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        avatarStrip()
                        Text(participantBreakdown())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
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
                    Circle().strokeBorder(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 3)
                )
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.15), in: Circle())
                    .overlay(
                        Circle().strokeBorder(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 3)
                    )
            }
            Spacer(minLength: 0)
        }
    }

    /// "5 confirmados · 2 tal vez · 1 no va". Sólo lista buckets con count > 0.
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
        if declined > 0  { parts.append("\(declined) no \(declined == 1 ? "va" : "van")") }
        if pending > 0 && parts.isEmpty {
            parts.append("\(pending) sin respuesta")
        }
        return parts.isEmpty ? "Sin respuestas todavía" : parts.joined(separator: " · ")
    }

    // MARK: - 4. Información (Apple Settings style)

    @ViewBuilder
    private func infoSection(_ event: CalendarEvent) -> some View {
        let rows = infoRows(event)
        VStack(alignment: .leading, spacing: 12) {
            Text("Información")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    infoRow(label: row.label, value: row.value)
                    if idx < rows.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private struct InfoRow {
        let label: String
        let value: String
    }

    private func infoRows(_ event: CalendarEvent) -> [InfoRow] {
        var rows: [InfoRow] = []
        rows.append(InfoRow(label: "Organizador", value: store.displayName(for: event.hostActorId) + (isHost ? " (tú)" : "")))
        if let location = event.locationText, !location.isEmpty {
            rows.append(InfoRow(label: "Ubicación", value: location))
        }
        if event.isRecurring {
            rows.append(InfoRow(label: "Repetición", value: recurrenceLabel(event)))
        }
        rows.append(InfoRow(label: "Contexto", value: context.displayName))
        return rows
    }

    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func recurrenceLabel(_ event: CalendarEvent) -> String {
        guard let rule = event.recurrenceRule?.uppercased() else { return "Recurrente" }
        if rule.contains("FREQ=WEEKLY") { return "Semanal" }
        if rule.contains("FREQ=DAILY")  { return "Diario" }
        if rule.contains("FREQ=MONTHLY") { return "Mensual" }
        if rule.contains("FREQ=YEARLY") { return "Anual" }
        return "Recurrente"
    }

    // MARK: - 5. Check-in

    @ViewBuilder
    private func checkInSection(_ event: CalendarEvent) -> some View {
        let mine = store.myParticipation(myActorId: myActorId)
        let shouldShow = event.isScheduled
            && shouldShowCheckIn(event)
            && mine?.checkedIn != true
            && mine?.status != "declined"
            && mine?.status != "cancelled"

        if shouldShow {
            Button {
                Task { await selfCheckIn() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Llegué")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
            .disabled(runner.isRunning)
        }
    }

    /// El evento ya inició (o está por iniciar en breve).
    private func shouldShowCheckIn(_ event: CalendarEvent) -> Bool {
        guard let starts = event.startsAt else { return false }
        return Date() >= starts.addingTimeInterval(-30 * 60)
    }

    // MARK: - 6. Recursos relacionados

    @ViewBuilder
    private func relatedResourcesSection(_ event: CalendarEvent) -> some View {
        let resources = relatedResources
        if resources.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recursos")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(resources.enumerated()), id: \.offset) { idx, item in
                        Button {
                            pushedResource = item.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox.fill")
                                    .foregroundStyle(.tint)
                                    .frame(width: 32, height: 32)
                                    .background(Color.accentColor.opacity(0.12), in: Circle())
                                Text(item.title)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < resources.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private struct RelatedItem: Identifiable {
        let id: UUID
        let title: String
    }

    /// Recursos únicos referenciados en la actividad de este evento.
    /// El título viene del `payload.title` cuando existe.
    private var relatedResources: [RelatedItem] {
        var seen: Set<UUID> = []
        var out: [RelatedItem] = []
        for activity in eventActivity {
            guard let id = activity.resourceId, !seen.contains(id) else { continue }
            seen.insert(id)
            let title = activity.payload?["title"]?.stringValue ?? "Recurso"
            out.append(RelatedItem(id: id, title: title))
        }
        return out
    }

    // MARK: - 7. Decisiones relacionadas

    @ViewBuilder
    private func relatedDecisionsSection(_ event: CalendarEvent) -> some View {
        let decisions = relatedDecisions
        if decisions.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Decisiones")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(decisions.enumerated()), id: \.offset) { idx, item in
                        Button {
                            pushedDecision = item.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.indigo)
                                    .frame(width: 32, height: 32)
                                    .background(Color.indigo.opacity(0.12), in: Circle())
                                Text(item.title)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < decisions.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var relatedDecisions: [RelatedItem] {
        var seen: Set<UUID> = []
        var out: [RelatedItem] = []
        for activity in eventActivity {
            guard let id = activity.decisionId, !seen.contains(id) else { continue }
            seen.insert(id)
            let title = activity.payload?["title"]?.stringValue ?? "Decisión"
            out.append(RelatedItem(id: id, title: title))
        }
        return out
    }

    // MARK: - Más acciones (•••)

    @ViewBuilder
    private func moreMenu(_ event: CalendarEvent) -> some View {
        Menu {
            ForEach(moreActions(event)) { item in
                Button(role: item.isDestructive ? .destructive : nil) {
                    handleMoreAction(item.kind)
                } label: {
                    Label(item.label, systemImage: item.symbol)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Más acciones")
        }
    }

    private enum MoreActionKind {
        case recordExpense
        case createDecision
        case closeEvent
        case cancelParticipation
    }

    private struct MoreActionItem: Identifiable {
        let id = UUID()
        let kind: MoreActionKind
        let label: String
        let symbol: String
        let isDestructive: Bool
    }

    /// Sólo aparecen las acciones que el backend marca como `enabled` en
    /// `event_detail.available_actions`. Las acciones de participación
    /// (rsvp/check-in) NO van acá — viven en sus propias secciones arriba.
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
            default:
                break
            }
        }
        return out
    }

    private func handleMoreAction(_ kind: MoreActionKind) {
        switch kind {
        case .recordExpense:        pushedMoney = true
        case .createDecision:       pushedDecisions = true
        case .closeEvent:           isConfirmingClose = true
        case .cancelParticipation:  isConfirmingCancel = true
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
