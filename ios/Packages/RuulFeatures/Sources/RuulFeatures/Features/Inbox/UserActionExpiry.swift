import Foundation
import RuulCore

/// Per-`ActionType` TTL heuristics. UserAction no expone `expires_at`
/// (mig 00077: el atom es append-only y la expiración real vive en el
/// objeto referenciado — vote.closesAt, fine grace, etc.). Para la
/// urgency en el inbox derivamos el cierre desde `createdAt + TTL`
/// usando el default conocido del backend por tipo. Es una
/// aproximación: cuando el grupo override del default (governance
/// custom hours), el chip se desviará. P1 expone `expires_at` real en
/// UserAction y este helper queda como fallback.
public enum UserActionExpiry {

    /// TTL convencional por tipo. nil = sin deadline (rsvp, host
    /// assigned — el deadline real es la fecha del evento, fuera de
    /// scope del action).
    public static func defaultTTL(for type: ActionType) -> TimeInterval? {
        switch type {
        case .appealVotePending:      return 48 * 3600    // governance default
        case .fineProposalReview:     return 24 * 3600    // grace period (mig 00016)
        case .votePending:            return 48 * 3600    // governance default
        case .ruleChangeApplyPending: return 24 * 3600    // post-vote apply window
        case .slotPending:            return 24 * 3600    // slot offer window
        case .contributionDue,
             .compensationDue:        return 7 * 24 * 3600 // semana razonable
        case .finePending,
             .fineVoided,
             .rsvpPending,
             .hostAssigned,
             .assetActionApproval:    return nil
        }
    }

    /// Friendly remaining-time chip ("VENCE EN 12 H", "3 D", "30 MIN").
    /// Returns nil when:
    ///   - el tipo no tiene TTL convencional, o
    ///   - ya pasó el deadline (la UI debe mostrar "VENCIDA" — pero por
    ///     ahora simplemente omite el chip; el coordinador/cron se
    ///     encargan de resolverlo).
    /// Para deadlines cercanos (<1h) se usa minutos; resto horas/días.
    public static func remainingDescription(for action: UserAction, now: Date = .now) -> String? {
        guard let ttl = defaultTTL(for: action.actionType) else { return nil }
        let expiresAt = action.createdAt.addingTimeInterval(ttl)
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let minutes = Int(remaining / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 {
            return "VENCE EN \(days) D"
        }
        if hours >= 1 {
            return "VENCE EN \(hours) H"
        }
        return "VENCE EN \(max(1, minutes)) MIN"
    }
}
