import Testing
import Foundation
@testable import RuulCore

/// Beta 1 Consolidation W2-C3 regression coverage.
///
/// Bug: `SystemEventDetailView` rendered `event.eventType.rawString`
/// in two places when no explicit case mapping existed — leaking
/// internal model strings like "hoursBeforeEvent", "rsvpDeadlinePassed",
/// "fundDeposit" directly to the user.
///
/// Fix: every SystemEventType case has a Spanish-MX `humanLabel`.
/// rawString is purely internal.
@Suite("SystemEventType.humanLabel covers every case")
struct SystemEventTypeHumanLabelTests {
    @Test("event lifecycle types have humanLabel in Spanish")
    func eventLifecycle() {
        #expect(SystemEventType.eventCreated.humanLabel == "Evento creado")
        #expect(SystemEventType.eventClosed.humanLabel  == "Evento cerrado")
        #expect(SystemEventType.rsvpDeadlinePassed.humanLabel == "Cerró el plazo de confirmación")
        #expect(SystemEventType.hoursBeforeEvent.humanLabel.lowercased().contains("antes"))
    }

    @Test("rsvp + checkin types map to user language")
    func rsvpAndCheckin() {
        #expect(SystemEventType.rsvpSubmitted.humanLabel == "Confirmación de asistencia")
        #expect(SystemEventType.rsvpChangedSameDay.humanLabel == "Cambio de asistencia el mismo día")
        #expect(SystemEventType.checkInRecorded.humanLabel == "Llegada registrada")
        #expect(SystemEventType.checkInMissed.humanLabel == "No llegó")
    }

    @Test("fine + appeal + vote types map")
    func fineAppealVote() {
        #expect(SystemEventType.fineOfficialized.humanLabel == "Multa oficializada")
        #expect(SystemEventType.fineVoided.humanLabel == "Multa anulada")
        #expect(SystemEventType.finePaid.humanLabel == "Multa pagada")
        #expect(SystemEventType.appealCreated.humanLabel == "Apelación abierta")
        #expect(SystemEventType.voteResolved.humanLabel == "Votación cerrada")
    }

    @Test("fund + slot types map (no rawString leak even for Beta 1 hidden surfaces)")
    func fundAndSlot() {
        #expect(SystemEventType.fundCreated.humanLabel == "Fondo creado")
        #expect(SystemEventType.slotAssigned.humanLabel == "Cupo asignado")
        #expect(SystemEventType.slotExpired.humanLabel == "Cupo expirado")
    }

    @Test("rule + governance + member types map")
    func ruleAndMember() {
        #expect(SystemEventType.ruleEnabledChanged.humanLabel == "Acuerdo activado o apagado")
        #expect(SystemEventType.ruleAmountChanged.humanLabel == "Monto del acuerdo cambiado")
        #expect(SystemEventType.memberJoined.humanLabel == "Miembro nuevo")
        #expect(SystemEventType.memberLeft.humanLabel == "Miembro salió")
        #expect(SystemEventType.pendingChangeApplied.humanLabel == "Cambio aplicado")
    }

    @Test("unknown carries a friendly fallback (no rawString leak)")
    func unknownFallback() {
        let label = SystemEventType.unknown("hostAssigned").humanLabel
        #expect(label == "Actividad")
        #expect(!label.contains("hostAssigned"))
    }

    @Test("every case in CaseIterable-equivalent set returns non-empty, no English")
    func everyCaseCovered() {
        // We can't iterate the assoc-value enum with CaseIterable, so list
        // the cases explicitly and assert each maps to non-empty Spanish.
        let cases: [SystemEventType] = [
            .eventClosed, .eventCreated, .rsvpDeadlinePassed, .hoursBeforeEvent,
            .rsvpSubmitted, .rsvpChangedSameDay, .checkInRecorded, .checkInMissed,
            .eventDescriptionMissing,
            .slotAssigned, .slotDeclined, .slotExpired, .slotSwapRequested, .slotSwapApproved,
            .bookingCreated, .bookingCancelled, .bookingExpired, .assetCreated,
            .fineOfficialized, .fineVoided, .finePaid, .fineReminderSent,
            .appealCreated, .appealResolved,
            .voteOpened, .voteCast, .voteResolved,
            .fundCreated, .fundDeposit, .fundThresholdReached,
            .positionChanged, .memberJoined, .memberLeft,
            .ruleEnabledChanged, .ruleAmountChanged,
            .pendingChangeApplied,
        ]
        for c in cases {
            let label = c.humanLabel
            #expect(!label.isEmpty, "missing humanLabel for \(c)")
            // No camelCase rawString style identifiers should leak.
            let forbiddenSubstrings = ["hostAssigned", "rsvpDeadlinePassed", "fundDeposit", "rawString"]
            for forbidden in forbiddenSubstrings {
                #expect(!label.contains(forbidden), "humanLabel for \(c) leaks \(forbidden): \(label)")
            }
        }
    }
}
