import Foundation
import Supabase

protocol CheckInRepository: Actor {
    func selfCheckIn(eventId: UUID, userId: UUID, locationVerified: Bool) async throws -> RSVP
    func hostMarkCheckIn(eventId: UUID, memberId: UUID) async throws -> RSVP
    func qrScanCheckIn(eventId: UUID, memberId: UUID) async throws -> RSVP
}

// MARK: - Mock

actor MockCheckInRepository: CheckInRepository {
    private(set) var checkIns: [(eventId: UUID, memberId: UUID, method: CheckInMethod)] = []
    var nextError: EventError?
    var alreadyCheckedInIds: Set<UUID> = []  // memberIds already checked

    func selfCheckIn(eventId: UUID, userId: UUID, locationVerified: Bool) async throws -> RSVP {
        try await record(eventId: eventId, memberId: userId, method: .selfMethod, locationVerified: locationVerified)
    }

    func hostMarkCheckIn(eventId: UUID, memberId: UUID) async throws -> RSVP {
        try await record(eventId: eventId, memberId: memberId, method: .hostMarked, locationVerified: false)
    }

    func qrScanCheckIn(eventId: UUID, memberId: UUID) async throws -> RSVP {
        try await record(eventId: eventId, memberId: memberId, method: .qrScan, locationVerified: false)
    }

    private func record(eventId: UUID, memberId: UUID, method: CheckInMethod, locationVerified: Bool) async throws -> RSVP {
        if let err = nextError { nextError = nil; throw err }
        if alreadyCheckedInIds.contains(memberId) { throw EventError.alreadyCheckedIn }
        alreadyCheckedInIds.insert(memberId)
        checkIns.append((eventId: eventId, memberId: memberId, method: method))
        return RSVP(
            eventId: eventId,
            userId: memberId,
            status: .going,
            arrivedAt: .now,
            checkInMethod: method,
            checkInLocationVerified: locationVerified
        )
    }
}

// MARK: - Live

actor LiveCheckInRepository: CheckInRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func selfCheckIn(eventId: UUID, userId: UUID, locationVerified: Bool) async throws -> RSVP {
        try await callRPC(eventId: eventId, userId: userId, method: .selfMethod, locationVerified: locationVerified)
    }

    func hostMarkCheckIn(eventId: UUID, memberId: UUID) async throws -> RSVP {
        try await callRPC(eventId: eventId, userId: memberId, method: .hostMarked, locationVerified: false)
    }

    func qrScanCheckIn(eventId: UUID, memberId: UUID) async throws -> RSVP {
        try await callRPC(eventId: eventId, userId: memberId, method: .qrScan, locationVerified: false)
    }

    private func callRPC(eventId: UUID, userId: UUID, method: CheckInMethod, locationVerified: Bool) async throws -> RSVP {
        struct Params: Encodable {
            let p_event_id: String
            let p_user_id: String
            let p_method: String
            let p_location_verified: Bool
        }
        do {
            return try await client
                .rpc("check_in_v2", params: Params(
                    p_event_id: eventId.uuidString.lowercased(),
                    p_user_id: userId.uuidString.lowercased(),
                    p_method: method.rawValue,
                    p_location_verified: locationVerified
                ))
                .execute()
                .value
        } catch {
            throw EventError.checkInFailed(error.localizedDescription)
        }
    }
}
