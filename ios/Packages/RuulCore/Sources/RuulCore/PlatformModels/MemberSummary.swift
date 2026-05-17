import Foundation

/// Stats agregadas para un (group, member) — devueltas por el RPC
/// `get_member_summary` (mig 00254). Backend para MemberDetailView.
///
/// Atributos son optionals donde el server puede devolver null
/// (attendance_rate cuando no hay eventos elegibles, role/joined_at
/// cuando el subject no es ni fue miembro).
public struct MemberSummary: Sendable, Hashable, Codable {
    public let groupId: UUID
    public let userId: UUID
    public let isMember: Bool
    public let rsvpsTotal: Int
    public let rsvpsGoing: Int
    public let eventsAttended: Int
    public let eventsEligible: Int
    /// 0.0 ... 1.0 si hay eventos elegibles, nil si denominador = 0.
    public let attendanceRate: Double?
    public let finesPendingCount: Int
    public let finesPendingAmountCents: Int64
    public let finesPaidCount: Int
    public let finesPaidAmountCents: Int64
    public let votesCast: Int
    public let joinedAt: Date?
    public let role: String?
    public let active: Bool
    public let onCommittee: Bool?

    public init(
        groupId: UUID,
        userId: UUID,
        isMember: Bool,
        rsvpsTotal: Int,
        rsvpsGoing: Int,
        eventsAttended: Int,
        eventsEligible: Int,
        attendanceRate: Double?,
        finesPendingCount: Int,
        finesPendingAmountCents: Int64,
        finesPaidCount: Int,
        finesPaidAmountCents: Int64,
        votesCast: Int,
        joinedAt: Date?,
        role: String?,
        active: Bool,
        onCommittee: Bool?
    ) {
        self.groupId = groupId
        self.userId = userId
        self.isMember = isMember
        self.rsvpsTotal = rsvpsTotal
        self.rsvpsGoing = rsvpsGoing
        self.eventsAttended = eventsAttended
        self.eventsEligible = eventsEligible
        self.attendanceRate = attendanceRate
        self.finesPendingCount = finesPendingCount
        self.finesPendingAmountCents = finesPendingAmountCents
        self.finesPaidCount = finesPaidCount
        self.finesPaidAmountCents = finesPaidAmountCents
        self.votesCast = votesCast
        self.joinedAt = joinedAt
        self.role = role
        self.active = active
        self.onCommittee = onCommittee
    }

    public enum CodingKeys: String, CodingKey {
        case groupId                 = "group_id"
        case userId                  = "user_id"
        case isMember                = "is_member"
        case rsvpsTotal              = "rsvps_total"
        case rsvpsGoing              = "rsvps_going"
        case eventsAttended          = "events_attended"
        case eventsEligible          = "events_eligible"
        case attendanceRate          = "attendance_rate"
        case finesPendingCount       = "fines_pending_count"
        case finesPendingAmountCents = "fines_pending_amount_cents"
        case finesPaidCount          = "fines_paid_count"
        case finesPaidAmountCents    = "fines_paid_amount_cents"
        case votesCast               = "votes_cast"
        case joinedAt                = "joined_at"
        case role
        case active
        case onCommittee             = "on_committee"
    }

    public static func empty(groupId: UUID, userId: UUID) -> MemberSummary {
        MemberSummary(
            groupId: groupId,
            userId: userId,
            isMember: false,
            rsvpsTotal: 0,
            rsvpsGoing: 0,
            eventsAttended: 0,
            eventsEligible: 0,
            attendanceRate: nil,
            finesPendingCount: 0,
            finesPendingAmountCents: 0,
            finesPaidCount: 0,
            finesPaidAmountCents: 0,
            votesCast: 0,
            joinedAt: nil,
            role: nil,
            active: false,
            onCommittee: nil
        )
    }
}
