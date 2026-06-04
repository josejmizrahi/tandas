import Foundation
import Observation

/// F.7 — store de eventos del contexto.
@MainActor
@Observable
public final class EventsStore {
    public private(set) var events: [CalendarEvent] = []
    public private(set) var myPermissions: [String] = []
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient
    /// Para resolver "Tú" cuando el actor no está en members
    /// (contexto personal o un actor que ya salió del contexto).
    private var myActorId: UUID?

    public init(rpc: any RuulRPCClient, myActorId: UUID? = nil) {
        self.rpc = rpc
        self.myActorId = myActorId
    }

    public init(rpc: any RuulRPCClient, previewEvents: [CalendarEvent], permissions: [String] = []) {
        self.rpc = rpc
        self.events = previewEvents
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public var upcoming: [CalendarEvent] {
        events.filter(\.isScheduled).sorted { ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture) }
    }

    public var past: [CalendarEvent] {
        events.filter { !$0.isScheduled }.sorted { ($0.startsAt ?? .distantPast) > ($1.startsAt ?? .distantPast) }
    }

    public func load(context: AppContext) async {
        if events.isEmpty { phase = .loading }
        do {
            async let eventsTask = rpc.listEvents(contextId: context.id)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loaded, summary) = try await (eventsTask, summaryTask)
            events = loaded
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func canCreate(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("events.create")
    }

    public func canManage(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("events.manage")
    }

    public func createEvent(_ input: CreateEventInput, context: AppContext) async throws -> CalendarEvent {
        let event = try await rpc.createCalendarEvent(input)
        await load(context: context)
        return event
    }
}

/// F.7 — store del detalle de un evento: evento + participantes + acciones.
@MainActor
@Observable
public final class EventDetailStore {
    public private(set) var event: CalendarEvent?
    public private(set) var participants: [EventParticipant] = []
    public private(set) var members: [ContextMember] = []
    public private(set) var myPermissions: [String] = []
    /// F.2X.4 — Acciones canónicas del evento desde `event_detail.available_actions`.
    /// La vista renderiza la sección "⚡ Acciones rápidas" exclusivamente desde aquí.
    public private(set) var availableActions: [AvailableAction] = []
    public private(set) var phase: StorePhase = .idle
    /// Resultado del último check-in (para mostrar "llegaste tarde → multa").
    public private(set) var lastCheckIn: CheckInResult?
    /// Resultado de la última cancelación.
    public private(set) var lastCancellation: CancelParticipationResult?
    /// Resultado del último cierre.
    public private(set) var lastClose: CloseEventResult?

    private let rpc: any RuulRPCClient
    /// Para resolver "Tú" cuando el actor no está en members
    /// (contexto personal o un actor que ya salió del contexto).
    private var myActorId: UUID?

    public init(rpc: any RuulRPCClient, myActorId: UUID? = nil) {
        self.rpc = rpc
        self.myActorId = myActorId
    }

    public func load(eventId: UUID, context: AppContext) async {
        if event == nil { phase = .loading }
        do {
            // F.2X.4 — event_detail consolida event + participants + available_actions.
            // Sigue necesitando context_summary para members + my_permissions porque
            // event_detail no los incluye (members vive en el contexto).
            async let detailTask = rpc.eventDetail(eventId: eventId)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (detail, summary) = try await (detailTask, summaryTask)
            event = detail.event
            participants = detail.participants
            availableActions = detail.availableActions
            members = summary.members
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func displayName(for actorId: UUID?) -> String {
        guard let actorId else { return "—" }
        if let member = members.first(where: { $0.actorId == actorId }) { return member.displayName }
        if actorId == myActorId { return "Tú" }
        return "Alguien"
    }

    public func myParticipation(myActorId: UUID?) -> EventParticipant? {
        guard let myActorId else { return nil }
        return participants.first { $0.participantActorId == myActorId }
    }

    public func canManage(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("events.manage")
    }

    // MARK: - Acciones

    public func rsvp(_ status: RSVPStatus, eventId: UUID, context: AppContext) async throws {
        try await rpc.rsvpEvent(eventId: eventId, status: status)
        await load(eventId: eventId, context: context)
    }

    /// Check-in propio o de otro participante (host).
    public func checkIn(eventId: UUID, participantActorId: UUID?, context: AppContext) async throws -> CheckInResult {
        let result = try await rpc.checkInParticipant(eventId: eventId, participantActorId: participantActorId)
        lastCheckIn = result
        await load(eventId: eventId, context: context)
        return result
    }

    public func cancelParticipation(eventId: UUID, context: AppContext) async throws -> CancelParticipationResult {
        let result = try await rpc.cancelParticipation(eventId: eventId)
        lastCancellation = result
        await load(eventId: eventId, context: context)
        return result
    }

    public func closeEvent(eventId: UUID, context: AppContext) async throws -> CloseEventResult {
        let result = try await rpc.closeEvent(eventId: eventId)
        lastClose = result
        await load(eventId: eventId, context: context)
        return result
    }
}
