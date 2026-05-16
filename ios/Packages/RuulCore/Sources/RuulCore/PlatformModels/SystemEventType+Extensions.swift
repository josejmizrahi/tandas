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
        case .eventCancelled:         return "Evento cancelado"
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
        case .assetTransferred:       return "Recurso transferido"
        case .assetAssigned:          return "Recurso asignado"
        case .assetReturned:          return "Recurso devuelto"
        case .assetUsed:              return "Recurso usado"
        case .assetCheckedOut:        return "Recurso prestado"
        case .assetCheckedIn:         return "Recurso devuelto al grupo"
        case .custodyAssigned:        return "Custodia asignada"
        case .custodyReleased:        return "Custodia liberada"
        case .maintenanceLogged:      return "Mantenimiento registrado"
        case .maintenanceCompleted:   return "Mantenimiento completado"
        case .damageReported:         return "Daño reportado"
        case .valuationRecorded:      return "Valuación registrada"
        case .resourceLinked:         return "Recurso vinculado"
        case .resourceUnlinked:       return "Recurso desvinculado"

        // Right (Phase 2)
        case .rightCreated:           return "Derecho creado"
        case .rightTransferred:       return "Derecho transferido"
        case .rightDelegated:         return "Derecho delegado"
        case .rightRevoked:           return "Derecho revocado"
        case .rightExpired:           return "Derecho expirado"
        case .rightExercised:         return "Derecho ejercido"
        case .rightSuspended:         return "Derecho suspendido"
        case .rightRestored:          return "Derecho restaurado"

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
        case .fundLocked:             return "Fondo bloqueado"
        case .fundUnlocked:           return "Fondo desbloqueado"

        // Space (mig 00203)
        case .spaceCreated:           return "Espacio creado"

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

        // Resource lifecycle (mig 00186)
        case .resourceArchived:       return "Recurso archivado"
        case .resourceUnarchived:     return "Recurso restaurado"
        case .resourceRenamed:        return "Recurso renombrado"

        // Capability lifecycle (mig 00192)
        case .capabilityToggled:           return "Capacidad activada o apagada"
        case .capabilityConfigUpdated:     return "Configuración de capacidad editada"
        case .memberCapabilityOverridden:  return "Excepción de miembro aplicada"

        // Money / Governance flow (mig 00193)
        case .ledgerEntryCreated:     return "Movimiento de dinero registrado"
        case .warningEmitted:         return "Aviso emitido por regla"

        // Right lifecycle (mig 00198 + mig 00203_right_expiration_warning)
        case .rightExpiringSoon:      return "Derecho próximo a expirar"

        // Event lifecycle additions (mig 00208 — eventStarted, mig 00210 — eventUpdated)
        case .eventStarted:           return "Evento iniciado"
        case .eventUpdated:           return "Evento actualizado"

        // Asset rule overdue atoms (mig 00225 — Plans/Active/AssetRules.md §5)
        case .assetCheckoutOverdue:    return "Devolución vencida"
        case .assetMaintenanceOverdue: return "Mantenimiento atrasado"

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
             .assetCreated, .assetTransferred, .assetAssigned,
             .assetReturned, .assetUsed, .assetCheckedOut,
             .assetCheckedIn, .custodyAssigned, .custodyReleased,
             .maintenanceLogged, .maintenanceCompleted, .damageReported,
             .valuationRecorded, .resourceLinked, .resourceUnlinked,
             .eventCancelled, .eventStarted, .eventUpdated,
             .rightCreated, .rightTransferred, .rightDelegated,
             .rightRevoked, .rightExpired, .rightExercised,
             .rightSuspended, .rightRestored, .rightExpiringSoon,
             .fundCreated, .fundDeposit, .fundThresholdReached,
             .fundLocked, .fundUnlocked,
             .spaceCreated,
             .positionChanged,
             .ruleEnabledChanged, .ruleAmountChanged,
             .pendingChangeApplied,
             .inviteCodeRotated,
             .groupCreated, .groupArchived, .groupUnarchived,
             .groupRenamed, .governanceUpdated,
             .resourceArchived, .resourceUnarchived, .resourceRenamed,
             .capabilityToggled, .capabilityConfigUpdated, .memberCapabilityOverridden,
             .ledgerEntryCreated, .warningEmitted,
             .assetCheckoutOverdue, .assetMaintenanceOverdue:
            return false
        case .unknown:
            return false
        }
    }
}
