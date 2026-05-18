import SwiftUI
import RuulCore

@MainActor
public struct ActivityTab: View {
    @Environment(AppState.self) private var app
    @Environment(RootRouter.self) private var router
    let coordinator: ActivityCoordinator?

    public init(activity: ActivityCoordinator?) {
        self.coordinator = activity
    }

    public var body: some View {
        NavigationStack {
            if let coord = coordinator {
                ActivityView(coordinator: coord, onOpenRelated: openRelated)
                    .environment(app)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ruulAppToolbar()
            }
        }
    }

    /// Routes a SystemEvent's "Ver detalle" CTA al destino real (evento,
    /// multa, voto, recurso) según `event_type`. Sin esto, el detail
    /// sheet de SystemEvent terminaba como callejón sin salida — el
    /// usuario veía "Jose creó un evento" y no podía abrir el evento.
    ///
    /// Cobertura por dominio:
    ///   - eventCreated/Closed/Cancelled/...   → openResource(resourceId)
    ///   - fineOfficialized/Voided/Paid/...    → openFineDetail(referenceId)
    ///   - voteOpened/Resolved                  → openResource(referenceId) (V2 → openVoteDetail)
    ///   - resourceCreated/Renamed/Archived     → openResource(resourceId)
    ///   - asset/slot/fund/space/right events   → openResource(resourceId)
    /// El resto (rsvp, checkIn, ruleEnabled/Amount, member, pendingChange,
    /// inviteCodeRotated) no tienen destino canónico de detail screen
    /// hoy — quedan como no-op (el sheet se cierra y no pasa nada
    /// adicional, pero al menos el sheet ya entrega la info).
    private func openRelated(_ event: SystemEvent) {
        switch event.eventType {
        // Resource-shaped: pushea el resource detail polimórfico
        case .eventCreated, .eventClosed, .eventCancelled, .eventStarted,
             .eventUpdated, .rsvpDeadlinePassed, .hoursBeforeEvent,
             .eventDescriptionMissing, .slotAssigned, .slotDeclined, .slotExpired,
             .slotSwapRequested, .slotSwapApproved, .bookingCreated, .bookingCancelled,
             .bookingExpired, .assetCreated, .assetTransferred, .assetAssigned,
             .assetReturned, .assetCheckedOut, .assetCheckedIn, .assetCheckoutOverdue,
             .assetMaintenanceOverdue, .assetUsed, .custodyAssigned, .custodyReleased,
             .maintenanceLogged, .maintenanceCompleted, .damageReported,
             .valuationRecorded, .fundCreated, .fundDeposit, .fundThresholdReached,
             .fundLocked, .fundUnlocked,
             .spaceCreated, .spaceBooked, .spaceReleased, .spaceCapacityReached,
             .spaceWaitlistJoined, .spaceWaitlistPromoted,
             .spaceAccessGranted, .spaceAccessRevoked,
             .bookingNoCheckIn,
             .rightCreated,
             .rightTransferred, .rightDelegated, .rightRevoked, .rightExpired,
             .rightExercised, .rightSuspended, .rightRestored, .rightExpiringSoon,
             .resourceArchived, .resourceUnarchived, .resourceRenamed,
             .resourceLinked, .resourceUnlinked, .capabilityToggled,
             .capabilityConfigUpdated:
            if let rid = event.resourceId { router.openResource(id: rid) }
        // Multas: el resourceId apunta al evento; el referenceId/fine_id
        // vive en payload. Por ahora abrimos el evento padre — abrir
        // FineDetail directo requiere parsear payload (V1.x follow-up).
        case .fineOfficialized, .fineVoided, .finePaid, .fineReminderSent,
             .appealCreated, .appealResolved:
            if let rid = event.resourceId { router.openResource(id: rid) }
        case .voteOpened, .voteCast, .voteResolved:
            if let rid = event.resourceId { router.openResource(id: rid) }
        default:
            // RSVP/checkIn/rule/member/governance/groupCreated/etc no tienen
            // detail screen propio. El sheet de SystemEvent ya entregó la
            // info — no-op aquí evita un dead-end CTA.
            break
        }
    }
}
