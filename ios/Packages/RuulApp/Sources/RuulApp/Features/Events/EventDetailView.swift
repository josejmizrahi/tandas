import SwiftUI
import RuulCore

/// F.7 — detalle de un evento: RSVP, check-in (propio y del host),
/// cancelar asistencia y cerrar el evento.
///
/// Las consecuencias (multa por tarde, multa por cancelar el mismo día) las
/// genera el backend vía rule engine — la vista solo las informa.
public struct EventDetailView: View {
    let eventId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: EventDetailStore
    @State private var runner = ActionRunner()
    @State private var checkInNotice: String?
    @State private var isConfirmingCancel = false
    @State private var isConfirmingClose = false

    public init(eventId: UUID, context: AppContext, container: DependencyContainer) {
        self.eventId = eventId
        self.context = context
        self.container = container
        _store = State(initialValue: EventDetailStore(rpc: container.rpc))
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }
    private var isHost: Bool { store.event?.hostActorId == myActorId }

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
        .task {
            await store.load(eventId: eventId, context: context)
        }
        .refreshable {
            await store.load(eventId: eventId, context: context)
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
    }

    // MARK: - Contenido

    @ViewBuilder
    private func detailList(_ event: CalendarEvent) -> some View {
        List {
            headerSection(event)

            if event.isScheduled {
                rsvpSection(event)
            }

            participantsSection(event)

            if event.isScheduled {
                hostSection(event)
            }
        }
    }

    @ViewBuilder
    private func headerSection(_ event: CalendarEvent) -> some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: event.type.symbolName)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.headline)
                    Text(event.type.label + (event.isRecurring ? " · Semanal" : ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if let starts = event.startsAt {
                InfoRow(symbolName: "clock", title: "Cuándo", value: starts.formatted(date: .complete, time: .shortened))
            }
            if let location = event.locationText, !location.isEmpty {
                InfoRow(symbolName: "mappin.and.ellipse", title: "Dónde", value: location)
            }
            InfoRow(
                symbolName: "person.fill.checkmark",
                title: "Host",
                value: store.displayName(for: event.hostActorId) + (isHost ? " (tú)" : "")
            )

            if !event.isScheduled {
                HStack {
                    Text("Estado")
                    Spacer()
                    StatusBadge(event.isCompleted ? "Cerrado" : "Cancelado", color: event.isCompleted ? .gray : .red)
                }
            }
        }
    }

    // MARK: - RSVP + acciones propias

    @ViewBuilder
    private func rsvpSection(_ event: CalendarEvent) -> some View {
        let mine = store.myParticipation(myActorId: myActorId)

        Section("Tu asistencia") {
            if let mine {
                HStack {
                    Text("Estado")
                    Spacer()
                    StatusBadge(mine.statusLabel, color: participantColor(mine.status))
                }
                if let minutesLate = mine.minutesLate, minutesLate > 0 {
                    InfoRow(
                        symbolName: "clock.badge.exclamationmark",
                        title: "Llegaste tarde",
                        value: "\(Int(minutesLate)) min",
                        tint: .orange
                    )
                }
            }

            // RSVP controls
            if mine?.checkedIn != true && mine?.status != "cancelled" {
                HStack(spacing: 12) {
                    rsvpButton("Voy", status: .going, isCurrent: mine?.status == "going")
                    rsvpButton("Tal vez", status: .maybe, isCurrent: mine?.status == "maybe")
                    rsvpButton("No voy", status: .declined, isCurrent: mine?.status == "declined")
                }
                .buttonStyle(.borderless)
            }

            // Check-in propio
            if mine?.checkedIn != true && mine?.status != "cancelled" && mine?.status != "declined" {
                Button {
                    Task { await selfCheckIn() }
                } label: {
                    Label("Hacer check-in", systemImage: "checkmark.circle.fill")
                }
                .disabled(runner.isRunning)
            }

            // Cancelar asistencia
            if mine?.status != "cancelled" && mine?.checkedIn != true {
                Button(role: .destructive) {
                    isConfirmingCancel = true
                } label: {
                    Label("Cancelar mi asistencia", systemImage: "xmark.circle")
                }
                .disabled(runner.isRunning)
            }
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
    }

    @ViewBuilder
    private func rsvpButton(_ label: String, status: RSVPStatus, isCurrent: Bool) -> some View {
        Button {
            Task {
                await runner.run {
                    try await store.rsvp(status, eventId: eventId, context: context)
                }
            }
        } label: {
            Text(label)
                .font(.callout.weight(isCurrent ? .bold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    isCurrent ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill),
                    in: Capsule()
                )
        }
        .disabled(runner.isRunning)
    }

    // MARK: - Participantes (con check-in del host)

    @ViewBuilder
    private func participantsSection(_ event: CalendarEvent) -> some View {
        let canCheckInOthers = event.isScheduled && (isHost || store.canManage(in: context))

        Section("Participantes (\(store.participants.count))") {
            ForEach(store.participants) { participant in
                HStack(spacing: 12) {
                    ActorInitialsView(name: store.displayName(for: participant.participantActorId), size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.displayName(for: participant.participantActorId))
                        if let minutes = participant.minutesLate, minutes > 0 {
                            Text("Llegó \(Int(minutes)) min tarde")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    StatusBadge(participant.statusLabel, color: participantColor(participant.status))

                    // CheckInPanel: el host puede registrar la llegada de cada uno
                    if canCheckInOthers && !participant.checkedIn
                        && participant.status != "cancelled" && participant.status != "declined" {
                        Button {
                            Task { await hostCheckIn(participant) }
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .disabled(runner.isRunning)
                    }
                }
            }
        }
    }

    // MARK: - Acciones del host

    @ViewBuilder
    private func hostSection(_ event: CalendarEvent) -> some View {
        if isHost || store.canManage(in: context) {
            Section("Administrar evento") {
                Button {
                    isConfirmingClose = true
                } label: {
                    Label("Cerrar evento", systemImage: "checkmark.seal")
                }
                .disabled(runner.isRunning)
            } footer: {
                if event.isRecurring {
                    Text("Al cerrar: los que no llegaron quedan como no-show, se crea el evento de la próxima semana y el host rota al siguiente miembro.")
                } else {
                    Text("Al cerrar: los que no llegaron quedan como no-show.")
                }
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
        }
    }

    // MARK: - Acciones

    private func selfCheckIn() async {
        await runner.run {
            let result = try await store.checkIn(eventId: eventId, participantActorId: nil, context: context)
            checkInNotice = checkInMessage(result)
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
        }
    }

    private func checkInMessage(_ result: CheckInResult) -> String {
        if result.isLate, let minutes = result.minutesLate {
            return "Llegada tarde (\(Int(minutes)) min). Si hay regla de multa, ya se aplicó."
        }
        return "Llegada a tiempo. ✅"
    }

    private func cancelParticipation() async {
        await runner.run {
            let result = try await store.cancelParticipation(eventId: eventId, context: context)
            if result.sameDayCancellation {
                checkInNotice = "Cancelaste el mismo día del evento. Si hay regla de multa, ya se aplicó."
            }
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
        }
    }

    private func participantColor(_ status: String) -> Color {
        switch status {
        case "going", "attended": return .green
        case "late": return .orange
        case "maybe", "invited": return .blue
        case "declined", "cancelled", "no_show": return .red
        default: return .secondary
        }
    }
}

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
