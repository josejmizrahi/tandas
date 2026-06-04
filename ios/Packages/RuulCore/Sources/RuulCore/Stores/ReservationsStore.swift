import Foundation
import Observation

/// F.9 — store de reservaciones de un recurso (+ conflictos abiertos).
@MainActor
@Observable
public final class ReservationsStore {
    public private(set) var reservations: [Reservation] = []
    public private(set) var conflicts: [ReservationConflict] = []
    public private(set) var members: [ContextMember] = []
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

    public init(
        rpc: any RuulRPCClient,
        previewReservations: [Reservation],
        conflicts: [ReservationConflict] = [],
        members: [ContextMember] = [],
        permissions: [String] = []
    ) {
        self.rpc = rpc
        self.reservations = previewReservations
        self.conflicts = conflicts
        self.members = members
        self.myPermissions = permissions
        self.phase = .loaded
    }

    public var openConflicts: [ReservationConflict] { conflicts.filter(\.isOpen) }

    public var upcoming: [Reservation] {
        reservations
            .filter { $0.endsAt > Date() && $0.status != "cancelled" && $0.status != "rejected" }
            .sorted { $0.startsAt < $1.startsAt }
    }

    public var pastOrInactive: [Reservation] {
        reservations
            .filter { $0.endsAt <= Date() || $0.status == "cancelled" || $0.status == "rejected" }
            .sorted { $0.startsAt > $1.startsAt }
    }

    public func load(resourceId: UUID, context: AppContext) async {
        if reservations.isEmpty { phase = .loading }
        do {
            async let reservationsTask = rpc.listReservations(resourceId: resourceId)
            async let conflictsTask = rpc.listConflicts(resourceId: resourceId)
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            let (loadedReservations, loadedConflicts, summary) = try await (reservationsTask, conflictsTask, summaryTask)
            reservations = loadedReservations
            conflicts = loadedConflicts
            members = summary.members
            myPermissions = summary.myPermissions
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Reservaciones que cubren un día dado (para el calendario).
    /// Excluye canceladas/rechazadas; ordena por inicio.
    public func reservations(covering day: Date, calendar: Calendar = .current) -> [Reservation] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return reservations
            .filter { $0.status != "cancelled" && $0.status != "rejected" }
            .filter { $0.startsAt < dayEnd && $0.endsAt > dayStart }
            .sorted { $0.startsAt < $1.startsAt }
    }

    public func displayName(for actorId: UUID?) -> String {
        guard let actorId else { return "—" }
        if let member = members.first(where: { $0.actorId == actorId }) { return member.displayName }
        if actorId == myActorId { return "Tú" }
        return "Alguien"
    }

    public func reservation(byId id: UUID) -> Reservation? {
        reservations.first { $0.id == id }
    }

    public func canManage(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("reservations.manage")
    }

    public func canRequest(in context: AppContext) -> Bool {
        context.isPersonal || myPermissions.contains("reservations.request")
    }

    // MARK: - Acciones

    public func request(_ input: RequestReservationInput, context: AppContext) async throws -> ReservationRequestResult {
        let result = try await rpc.requestReservation(input)
        await load(resourceId: input.resourceId, context: context)
        return result
    }

    public func approve(reservationId: UUID, resourceId: UUID, context: AppContext) async throws {
        try await rpc.approveReservation(reservationId: reservationId)
        await load(resourceId: resourceId, context: context)
    }

    public func confirm(reservationId: UUID, resourceId: UUID, context: AppContext) async throws {
        try await rpc.confirmReservation(reservationId: reservationId)
        await load(resourceId: resourceId, context: context)
    }

    public func cancel(reservationId: UUID, resourceId: UUID, context: AppContext) async throws {
        try await rpc.cancelReservation(reservationId: reservationId)
        await load(resourceId: resourceId, context: context)
    }

    public func resolveConflict(conflictId: UUID, winnerReservationId: UUID, resourceId: UUID, context: AppContext) async throws {
        try await rpc.resolveReservationConflict(conflictId: conflictId, winnerReservationId: winnerReservationId)
        await load(resourceId: resourceId, context: context)
    }

    /// R.2S.7 — resuelve un conflicto usando uno de los 8 modelos. Devuelve el
    /// `ResolveConflictResult` para que la UI pueda explicar lo que pasó
    /// (sorteo ganado por X, split en hora Y, etc.).
    @discardableResult
    public func resolveConflict(
        conflictId: UUID,
        resolutionModel: ResolutionModel,
        winnerReservationId: UUID?,
        resourceId: UUID,
        context: AppContext
    ) async throws -> ResolveConflictResult {
        let result = try await rpc.resolveReservationConflictWith(
            conflictId: conflictId,
            resolutionModel: resolutionModel,
            winnerReservationId: winnerReservationId,
            metadata: nil
        )
        await load(resourceId: resourceId, context: context)
        return result
    }
}
