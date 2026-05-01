import Foundation
import Supabase

protocol RSVPRepository: Actor {
    func rsvps(for eventId: UUID) async throws -> [RSVP]
    func myRSVP(for eventId: UUID, userId: UUID) async throws -> RSVP?
    func setRSVP(eventId: UUID, status: RSVPStatus, plusOnes: Int, reason: String?) async throws -> RSVP
    func promoteFromWaitlist(eventId: UUID) async throws -> RSVP
}

// MARK: - Mock

actor MockRSVPRepository: RSVPRepository {
    private(set) var allRSVPs: [RSVP] = []
    var nextSetError: EventError?
    var nextPromoteError: EventError?

    init(seed: [RSVP] = []) { self.allRSVPs = seed }

    func rsvps(for eventId: UUID) async throws -> [RSVP] {
        allRSVPs.filter { $0.eventId == eventId }
    }

    func myRSVP(for eventId: UUID, userId: UUID) async throws -> RSVP? {
        allRSVPs.first { $0.eventId == eventId && $0.userId == userId }
    }

    func setRSVP(eventId: UUID, status: RSVPStatus, plusOnes: Int, reason: String?) async throws -> RSVP {
        if let err = nextSetError { nextSetError = nil; throw err }
        let userId = UUID()  // mock current user
        let new = RSVP(
            id: UUID(),
            eventId: eventId,
            userId: userId,
            status: status,
            respondedAt: .now,
            cancelledReason: reason,
            plusOnes: plusOnes
        )
        allRSVPs.removeAll { $0.eventId == eventId && $0.userId == userId }
        allRSVPs.append(new)
        return new
    }

    func promoteFromWaitlist(eventId: UUID) async throws -> RSVP {
        if let err = nextPromoteError { nextPromoteError = nil; throw err }
        guard let idx = allRSVPs.firstIndex(where: {
            $0.eventId == eventId && $0.status == .waitlisted
        }) else {
            throw EventError.notFound
        }
        let original = allRSVPs[idx]
        let promoted = RSVP(
            id: original.id,
            eventId: original.eventId,
            userId: original.userId,
            status: .going,
            respondedAt: .now,
            cancelledReason: nil,
            arrivedAt: original.arrivedAt,
            checkInMethod: original.checkInMethod,
            checkInLocationVerified: original.checkInLocationVerified,
            markedBy: original.markedBy,
            plusOnes: original.plusOnes,
            waitlistPosition: nil
        )
        allRSVPs[idx] = promoted
        return promoted
    }
}

// MARK: - Live

actor LiveRSVPRepository: RSVPRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func rsvps(for eventId: UUID) async throws -> [RSVP] {
        do {
            return try await client
                .from("event_attendance")
                .select("*")
                .eq("event_id", value: eventId.uuidString.lowercased())
                .execute()
                .value
        } catch {
            throw EventError.fetchFailed(error.localizedDescription)
        }
    }

    func myRSVP(for eventId: UUID, userId: UUID) async throws -> RSVP? {
        do {
            let row: RSVP? = try? await client
                .from("event_attendance")
                .select("*")
                .eq("event_id", value: eventId.uuidString.lowercased())
                .eq("user_id", value: userId.uuidString.lowercased())
                .single()
                .execute()
                .value
            return row
        }
    }

    func setRSVP(eventId: UUID, status: RSVPStatus, plusOnes: Int, reason: String?) async throws -> RSVP {
        // .waitlisted is server-assigned (auto when at capacity); never sent
        // by client. Coerce to .going so the RPC can decide.
        let requested: RSVPStatus = (status == .waitlisted) ? .going : status

        struct Params: Encodable {
            let p_event_id: String
            let p_status: String
            let p_plus_ones: Int
            let p_reason: String?
        }
        do {
            let row: RSVP = try await client
                .rpc("set_rsvp_v2", params: Params(
                    p_event_id: eventId.uuidString.lowercased(),
                    p_status: requested.rawValue,
                    p_plus_ones: plusOnes,
                    p_reason: reason
                ))
                .execute()
                .value
            return row
        } catch {
            throw EventError.rsvpFailed(error.localizedDescription)
        }
    }

    func promoteFromWaitlist(eventId: UUID) async throws -> RSVP {
        struct Params: Encodable { let p_event_id: String }
        do {
            return try await client
                .rpc("promote_from_waitlist", params: Params(
                    p_event_id: eventId.uuidString.lowercased()
                ))
                .execute()
                .value
        } catch {
            throw EventError.rsvpFailed(error.localizedDescription)
        }
    }
}
