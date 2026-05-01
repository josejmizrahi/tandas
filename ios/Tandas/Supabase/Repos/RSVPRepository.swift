import Foundation
import Supabase

protocol RSVPRepository: Actor {
    func rsvps(for eventId: UUID) async throws -> [RSVP]
    func myRSVP(for eventId: UUID, userId: UUID) async throws -> RSVP?
    func setRSVP(eventId: UUID, status: RSVPStatus, reason: String?) async throws -> RSVP
}

// MARK: - Mock

actor MockRSVPRepository: RSVPRepository {
    private(set) var allRSVPs: [RSVP] = []
    var nextSetError: EventError?

    init(seed: [RSVP] = []) { self.allRSVPs = seed }

    func rsvps(for eventId: UUID) async throws -> [RSVP] {
        allRSVPs.filter { $0.eventId == eventId }
    }

    func myRSVP(for eventId: UUID, userId: UUID) async throws -> RSVP? {
        allRSVPs.first { $0.eventId == eventId && $0.userId == userId }
    }

    func setRSVP(eventId: UUID, status: RSVPStatus, reason: String?) async throws -> RSVP {
        if let err = nextSetError { nextSetError = nil; throw err }
        let userId = UUID()  // mock current user
        let new = RSVP(
            id: UUID(),
            eventId: eventId,
            userId: userId,
            status: status,
            respondedAt: .now,
            cancelledReason: reason
        )
        allRSVPs.removeAll { $0.eventId == eventId && $0.userId == userId }
        allRSVPs.append(new)
        return new
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

    func setRSVP(eventId: UUID, status: RSVPStatus, reason: String?) async throws -> RSVP {
        struct Params: Encodable {
            let p_event_id: String
            let p_status: String
        }
        do {
            let row: RSVP = try await client
                .rpc("set_rsvp", params: Params(
                    p_event_id: eventId.uuidString.lowercased(),
                    p_status: status.rawValue
                ))
                .execute()
                .value
            // Reason stored separately because set_rsvp doesn't take it.
            if let reason, !reason.isEmpty {
                let userId = try await client.auth.session.user.id
                try await client
                    .from("event_attendance")
                    .update(["cancelled_reason": reason])
                    .eq("event_id", value: eventId.uuidString.lowercased())
                    .eq("user_id", value: userId.uuidString.lowercased())
                    .execute()
            }
            return row
        } catch {
            throw EventError.rsvpFailed(error.localizedDescription)
        }
    }
}
