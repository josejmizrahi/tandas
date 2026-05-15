import Foundation

public extension SystemEventType {
    /// Spanish-MX user-facing label for every SystemEventType case.
    ///
    /// Beta 1 W2-C3: SystemEventDetailView used to fall through to
    /// `rawString` for half the cases, leaking model strings like
    /// "hoursBeforeEvent" / "rsvpDeadlinePassed" / "fundDeposit"
    /// directly to users. `humanLabel` is the canonical user-facing
    /// translation; rawString stays internal-only.
    ///
    /// Keep alphabetized within sections to make new-case adds obvious.
    var humanLabel: String {
        switch self {
        // Event lifecycle
        case .eventCreated:           return "Evento creado"
        case .eventClosed:            return "Evento cerrado"
        case .rsvpDeadlinePassed:     return "Cerró el plazo de confirmación"
        case .hoursBeforeEvent:       return "Antes del evento"

        // RSVP + attendance
        case .rsvpSubmitted:          return "Confirmación de asistencia"
        case .rsvpChangedSameDay:     return "Cambio de asistencia el mismo día"
        case .checkInRecorded:        return "Llegada registrada"
        case .checkInMissed:          return "No llegó"
        case .eventDescriptionMissing: return "Falta descripción del evento"

        // Slot / Asset / Booking (Phase 2)
        case .slotAssigned:           return "Cupo asignado"
        case .slotDeclined:           return "Cupo rechazado"
        case .slotExpired:            return "Cupo expirado"
        case .slotSwapRequested:      return "Cambio de cupo solicitado"
        case .slotSwapApproved:       return "Cambio de cupo aprobado"
        case .bookingCreated:         return "Reserva creada"
        case .bookingCancelled:       return "Reserva cancelada"
        case .bookingExpired:         return "Reserva expirada"
        case .assetCreated:           return "Recurso creado"

        // Fines + appeals + votes
        case .fineOfficialized:       return "Multa oficializada"
        case .fineVoided:             return "Multa anulada"
        case .finePaid:               return "Multa pagada"
        case .fineReminderSent:       return "Recordatorio de multa"
        case .appealCreated:          return "Apelación abierta"
        case .appealResolved:         return "Apelación resuelta"
        case .voteOpened:             return "Votación abierta"
        case .voteCast:               return "Voto emitido"
        case .voteResolved:           return "Votación cerrada"

        // Fund (Phase 2-3)
        case .fundCreated:            return "Fondo creado"
        case .fundDeposit:            return "Aportación al fondo"
        case .fundThresholdReached:   return "Fondo llegó a su meta"

        // Rotation / membership
        case .positionChanged:        return "Cambio de turno"
        case .memberJoined:           return "Miembro nuevo"
        case .memberLeft:             return "Miembro salió"

        // Rule audit
        case .ruleEnabledChanged:     return "Acuerdo activado o apagado"
        case .ruleAmountChanged:      return "Monto del acuerdo cambiado"

        // Governance
        case .pendingChangeApplied:   return "Cambio aplicado"
        case .inviteCodeRotated:      return "Código de invitación cambiado"

        // Group lifecycle (mig 00178)
        case .groupCreated:           return "Grupo creado"
        case .groupArchived:          return "Grupo archivado"
        case .groupUnarchived:        return "Grupo desarchivado"
        case .groupRenamed:           return "Grupo renombrado"
        case .governanceUpdated:      return "Gobernanza actualizada"

        // Future / unknown — never leak the raw payload string.
        case .unknown:                return "Actividad"
        }
    }

    /// True if this event type is purely rule-engine fuel and should
    /// NOT appear in the user-facing Activity feed. Synthetic markers
    /// emitted by crons / triggers to give the rule engine something
    /// to evaluate against — never user-meaningful.
    ///
    /// Beta 1 W2-D3: the Activity timeline (then GroupHistoryView,
    /// now ActivityView) used to clutter with "Quedan horas para un
    /// evento" rows from `hoursBeforeEvent` (every recurring event ×
    /// every reminder horizon). Audit Track D #6.
    var isHiddenFromUserActivity: Bool {
        switch self {
        case .hoursBeforeEvent,
             .rsvpDeadlinePassed,
             .eventDescriptionMissing:
            return true
        default:
            return false
        }
    }

    /// All event types currently considered rule-fuel and hidden from
    /// the Activity feed. Used by `SystemEventRepository` query/recent
    /// to apply a `NOT IN` filter at the SQL layer.
    static var userHiddenActivityTypes: [SystemEventType] {
        [.hoursBeforeEvent, .rsvpDeadlinePassed, .eventDescriptionMissing]
    }

    /// True if Sprint 1a / V1 has a TriggerEvaluator implementation.
    var isImplementedInV1: Bool {
        switch self {
        case .eventClosed, .checkInRecorded, .rsvpChangedSameDay,
             .hoursBeforeEvent, .rsvpSubmitted, .rsvpDeadlinePassed,
             .eventDescriptionMissing,
             .appealCreated, .appealResolved,
             .voteOpened, .voteCast, .voteResolved,
             .fineOfficialized, .fineVoided, .finePaid, .fineReminderSent,
             .eventCreated, .memberJoined, .memberLeft:
            return true
        case .checkInMissed,
             .slotAssigned, .slotDeclined, .slotExpired,
             .slotSwapRequested, .slotSwapApproved,
             .bookingCreated, .bookingCancelled, .bookingExpired,
             .assetCreated,
             .fundCreated, .fundDeposit, .fundThresholdReached,
             .positionChanged,
             .ruleEnabledChanged, .ruleAmountChanged,
             .pendingChangeApplied,
             .inviteCodeRotated,
             .groupCreated, .groupArchived, .groupUnarchived,
             .groupRenamed, .governanceUpdated:
            return false
        case .unknown:
            return false
        }
    }
}
