import Foundation
import RuulUI
import RuulCore

/// Maps a `SystemEvent` to display data for `RuulTimelineItem`. Decouples
/// the timeline UI primitive (icon/title/subtitle/timestamp/tone) from the
/// platform's event-type catalog.
public struct HistoryItemPresentation {
    public let icon: String
    public let title: String
    public let subtitle: String?
    public let timestamp: String
    public let tone: RuulTimelineItem.Tone

    private static func relativeString(for date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "es_MX")
        return f.localizedString(for: date, relativeTo: .now)
    }

    public init(event: SystemEvent, memberName: String? = nil) {
        let actor = memberName ?? "Alguien"
        switch event.eventType {
        case .eventCreated:
            self.icon = "calendar.badge.plus"
            self.title = "Se creó un evento"
            self.tone = .info
        case .eventClosed:
            self.icon = "calendar.badge.checkmark"
            self.title = "\(actor) cerró un evento"
            self.tone = .neutral
        case .rsvpDeadlinePassed:
            self.icon = "clock.badge.exclamationmark"
            self.title = "Cerró la deadline de RSVP"
            self.tone = .warning
        case .hoursBeforeEvent:
            self.icon = "clock"
            self.title = "Quedan horas para un evento"
            self.tone = .neutral
        case .rsvpSubmitted:
            self.icon = "checkmark.circle"
            self.title = "\(actor) respondió RSVP"
            self.tone = .positive
        case .rsvpChangedSameDay:
            self.icon = "arrow.uturn.backward.circle"
            self.title = "\(actor) cambió RSVP el mismo día"
            self.tone = .warning
        case .checkInRecorded:
            self.icon = "location.fill"
            self.title = "\(actor) llegó al evento"
            self.tone = .positive
        case .checkInMissed:
            self.icon = "location.slash"
            self.title = "\(actor) no apareció"
            self.tone = .negative
        case .eventDescriptionMissing:
            self.icon = "exclamationmark.bubble"
            self.title = "Falta descripción del evento"
            self.tone = .warning
        case .slotAssigned:
            self.icon = "ticket"
            self.title = "\(actor) recibió un cupo"
            self.tone = .info
        case .slotDeclined:
            self.icon = "ticket"
            self.title = "\(actor) rechazó un cupo"
            self.tone = .neutral
        case .slotExpired:
            self.icon = "ticket"
            self.title = "Un cupo expiró"
            self.tone = .warning
        case .fineOfficialized:
            self.icon = "creditcard.fill"
            self.title = "Se oficializó una multa"
            self.tone = .warning
        case .fineVoided:
            self.icon = "xmark.circle"
            self.title = "Se anuló una multa"
            self.tone = .neutral
        case .finePaid:
            self.icon = "creditcard.and.123"
            self.title = "\(actor) pagó una multa"
            self.tone = .positive
        case .fineReminderSent:
            self.icon = "bell.badge"
            self.title = "Recordatorio de multa pendiente"
            self.tone = .warning
        case .appealCreated:
            self.icon = "scales.tighten"
            self.title = "\(actor) apeló una multa"
            self.tone = .info
        case .appealResolved:
            self.icon = "scales.tighten"
            self.title = "Se resolvió una apelación"
            self.tone = .neutral
        case .voteOpened:
            self.icon = "hand.raised.fill"
            self.title = "Se abrió una votación"
            self.tone = .info
        case .voteCast:
            self.icon = "hand.raised"
            self.title = "\(actor) emitió su voto"
            self.tone = .neutral
        case .voteResolved:
            // Specialize for ledger_review failed → expense reversed.
            // Activity feed shows the same row to everyone (group-scoped);
            // the notification adds a private push to the affected member.
            let voteType = event.payload["vote_type"]?.stringValue
            let resolution = event.payload["resolution"]?.stringValue
            if voteType == "ledger_review" && resolution == "failed" {
                self.icon = "arrow.uturn.backward.circle.fill"
                self.title = "El grupo reversó un gasto"
                self.tone = .warning
            } else if voteType == "ledger_review" && resolution == "passed" {
                self.icon = "checkmark.seal.fill"
                self.title = "El grupo ratificó un gasto"
                self.tone = .positive
            } else {
                self.icon = "hand.thumbsup.fill"
                self.title = "Se cerró una votación"
                self.tone = .positive
            }
        case .fundDeposit:
            self.icon = "banknote.fill"
            self.title = "Se depositó al fondo"
            self.tone = .positive
        case .fundThresholdReached:
            self.icon = "trophy.fill"
            self.title = "El fondo alcanzó la meta"
            self.tone = .positive
        case .positionChanged:
            self.icon = "arrow.2.circlepath"
            self.title = "Cambió la rotación"
            self.tone = .neutral
        case .memberJoined:
            self.icon = "person.crop.circle.badge.plus"
            self.title = "\(actor) se unió al grupo"
            self.tone = .positive
        case .memberLeft:
            self.icon = "person.crop.circle.badge.minus"
            self.title = "\(actor) salió del grupo"
            self.tone = .neutral
        case .slotSwapRequested:
            self.icon = "arrow.left.arrow.right"
            self.title = "\(actor) pidió cambiar un cupo"
            self.tone = .info
        case .slotSwapApproved:
            self.icon = "arrow.left.arrow.right.circle.fill"
            self.title = "Se aprobó un cambio de cupo"
            self.tone = .positive
        case .bookingCreated:
            self.icon = "calendar.badge.plus"
            self.title = "\(actor) reservó un cupo"
            self.tone = .info
        case .bookingCancelled:
            self.icon = "calendar.badge.minus"
            self.title = "\(actor) canceló una reserva"
            self.tone = .neutral
        case .bookingExpired:
            self.icon = "calendar.badge.exclamationmark"
            self.title = "Una reserva expiró"
            self.tone = .warning
        case .assetCreated:
            self.icon = "house.fill"
            self.title = "\(actor) registró un recurso"
            self.tone = .info
        case .fundCreated:
            self.icon = "banknote"
            self.title = "\(actor) creó un fondo"
            self.tone = .info
        case .ruleEnabledChanged:
            self.icon = "switch.2"
            self.title = "\(actor) cambió el estado de una regla"
            self.tone = .neutral
        case .ruleAmountChanged:
            self.icon = "pencil.line"
            self.title = "\(actor) editó la multa de una regla"
            self.tone = .neutral
        case .pendingChangeApplied:
            self.icon = "checkmark.seal"
            self.title = "Se aplicó un cambio aprobado"
            self.tone = .positive
        case .inviteCodeRotated:
            self.icon = "link.badge.plus"
            self.title = "\(actor) rotó el código de invitación"
            self.tone = .neutral
        case .groupCreated:
            self.icon = "person.3.fill"
            self.title = "Se creó el grupo"
            self.tone = .info
        case .groupArchived:
            self.icon = "archivebox"
            self.title = "\(actor) archivó el grupo"
            self.tone = .neutral
        case .groupUnarchived:
            self.icon = "tray.and.arrow.up"
            self.title = "\(actor) restauró el grupo"
            self.tone = .info
        case .groupRenamed:
            self.icon = "pencil"
            self.title = "\(actor) renombró el grupo"
            self.tone = .neutral
        case .governanceUpdated:
            self.icon = "scalemass"
            self.title = "\(actor) actualizó la gobernanza"
            self.tone = .neutral
        case .resourceArchived:
            self.icon = "archivebox"
            self.title = "\(actor) archivó un recurso"
            self.tone = .neutral
        case .resourceUnarchived:
            self.icon = "tray.and.arrow.up"
            self.title = "\(actor) restauró un recurso"
            self.tone = .info
        case .resourceRenamed:
            self.icon = "pencil"
            self.title = "\(actor) renombró un recurso"
            self.tone = .neutral
        case .capabilityToggled:
            self.icon = "switch.2"
            self.title = "\(actor) cambió una capacidad"
            self.tone = .neutral
        case .capabilityConfigUpdated:
            self.icon = "slider.horizontal.3"
            self.title = "\(actor) editó la configuración de una capacidad"
            self.tone = .neutral
        case .memberCapabilityOverridden:
            self.icon = "person.fill.questionmark"
            self.title = "\(actor) aplicó una excepción de miembro"
            self.tone = .neutral
        case .ledgerEntryCreated:
            self.icon = "dollarsign.circle"
            self.title = "\(actor) registró un movimiento de dinero"
            self.tone = .neutral
        case .warningEmitted:
            self.icon = "exclamationmark.triangle"
            self.title = "Aviso emitido por regla"
            self.tone = .warning
        case .assetTransferred:
            self.icon = "arrow.left.arrow.right"
            self.title = "\(actor) transfirió un activo"
            self.tone = .info
        case .assetAssigned:
            self.icon = "person.crop.circle.badge.checkmark"
            self.title = "\(actor) recibió un activo"
            self.tone = .info
        case .assetReturned:
            self.icon = "arrow.uturn.backward"
            self.title = "\(actor) devolvió un activo"
            self.tone = .neutral
        case .custodyAssigned:
            self.icon = "person.text.rectangle"
            self.title = "\(actor) quedó como custodio"
            self.tone = .info
        case .custodyReleased:
            self.icon = "person.crop.rectangle.badge.xmark"
            self.title = "\(actor) liberó la custodia"
            self.tone = .neutral
        case .maintenanceLogged:
            self.icon = "wrench.and.screwdriver"
            self.title = "\(actor) registró mantenimiento"
            self.tone = .info
        case .maintenanceCompleted:
            self.icon = "checkmark.seal"
            self.title = "Se cerró un mantenimiento"
            self.tone = .positive
        case .damageReported:
            self.icon = "exclamationmark.triangle.fill"
            self.title = "\(actor) reportó un daño"
            self.tone = .warning
        case .assetUsed:
            self.icon = "hand.tap"
            self.title = "\(actor) usó un activo"
            self.tone = .neutral
        case .assetCheckedOut:
            self.icon = "arrow.up.right.square"
            self.title = "\(actor) sacó prestado un activo"
            self.tone = .info
        case .assetCheckedIn:
            self.icon = "arrow.down.left.square"
            self.title = "Se devolvió un activo"
            self.tone = .positive
        case .valuationRecorded:
            self.icon = "chart.line.uptrend.xyaxis"
            self.title = "\(actor) registró el valor"
            self.tone = .neutral

        // Fund lock lifecycle (mig 00202_fund_writers_balance_lifecycle)
        case .fundLocked:
            self.icon = "lock.fill"
            self.title = "\(actor) bloqueó un fondo"
            self.tone = .warning
        case .fundUnlocked:
            self.icon = "lock.open"
            self.title = "\(actor) desbloqueó un fondo"
            self.tone = .info

        // Right lifecycle (mig 00198_right_resource_canonical)
        case .rightCreated:
            self.icon = "key.fill"
            self.title = "\(actor) creó un derecho"
            self.tone = .info
        case .rightTransferred:
            self.icon = "arrow.left.arrow.right"
            self.title = "\(actor) transfirió un derecho"
            self.tone = .info
        case .rightDelegated:
            self.icon = "person.2.fill"
            self.title = "\(actor) delegó un derecho"
            self.tone = .info
        case .rightRevoked:
            self.icon = "xmark.octagon"
            self.title = "\(actor) revocó un derecho"
            self.tone = .negative
        case .rightExpired:
            self.icon = "clock.badge.xmark"
            self.title = "Un derecho expiró"
            self.tone = .neutral
        case .rightExercised:
            self.icon = "checkmark.seal.fill"
            self.title = "\(actor) ejerció un derecho"
            self.tone = .positive
        case .rightSuspended:
            self.icon = "pause.circle"
            self.title = "\(actor) suspendió un derecho"
            self.tone = .warning
        case .rightRestored:
            self.icon = "arrow.clockwise.circle"
            self.title = "\(actor) restauró un derecho"
            self.tone = .positive
        case .rightExpiringSoon:
            self.icon = "clock.badge.exclamationmark"
            self.title = "Un derecho está por expirar"
            self.tone = .warning

        // Resource links (mig 00202_event_resource_links)
        case .resourceLinked:
            self.icon = "link"
            self.title = "\(actor) vinculó un recurso al evento"
            self.tone = .info
        case .resourceUnlinked:
            self.icon = "link.badge.plus"
            self.title = "\(actor) desvinculó un recurso del evento"
            self.tone = .neutral

        // Event lifecycle — eventCancelled (mig 00203_event_cancelled_atom)
        case .eventCancelled:
            self.icon = "xmark.circle"
            self.title = "\(actor) canceló el evento"
            self.tone = .negative
        // Event lifecycle — eventStarted (mig 00208, cron-emitted)
        case .eventStarted:
            self.icon = "play.circle"
            self.title = "El evento empezó"
            self.tone = .info

        case .unknown:
            self.icon = "questionmark.circle"
            self.title = "Actividad"
            self.tone = .neutral
        }

        self.subtitle = nil
        self.timestamp = Self.relativeString(for: event.occurredAt)
    }
}
