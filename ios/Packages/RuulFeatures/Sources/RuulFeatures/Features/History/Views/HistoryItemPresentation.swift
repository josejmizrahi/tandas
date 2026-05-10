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
            self.icon = "hand.thumbsup.fill"
            self.title = "Se cerró una votación"
            self.tone = .positive
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
        case .ruleEnabledChanged:
            self.icon = "switch.2"
            self.title = "\(actor) cambió el estado de una regla"
            self.tone = .neutral
        case .ruleAmountChanged:
            self.icon = "pencil.line"
            self.title = "\(actor) editó la multa de una regla"
            self.tone = .neutral
        case .unknown:
            self.icon = "questionmark.circle"
            self.title = "Actividad"
            self.tone = .neutral
        }

        self.subtitle = nil
        self.timestamp = Self.relativeString(for: event.occurredAt)
    }
}
