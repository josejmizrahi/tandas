import Foundation
import Supabase
import OSLog

/// Real-time subscription to `event_attendance` row changes for a specific
/// event. When ANY user's RSVP changes, emits a typed `Change` event so the
/// EventDetailCoordinator can update its local state without a manual refetch.
///
/// Lifecycle:
/// - Caller `init` with the active event id.
/// - Caller observes `changes` (AsyncStream) and `await subscribe()`.
/// - On view disappear, caller `await unsubscribe()`.
///
/// Backed by Supabase Realtime v2 (`client.realtimeV2`). Falls back to a
/// no-op stream if Realtime isn't available (offline, server unreachable,
/// etc.) — clients still work via manual refresh + optimistic updates.
actor RSVPRealtimeService {
    enum Change: Sendable {
        case upsert(RSVP)
        case delete(rsvpId: UUID)
    }

    private let client: SupabaseClient
    private let eventId: UUID
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rsvp.realtime")

    private var channel: RealtimeChannelV2?
    private var continuation: AsyncStream<Change>.Continuation?
    nonisolated let changes: AsyncStream<Change>

    init(client: SupabaseClient, eventId: UUID) {
        self.client = client
        self.eventId = eventId
        var localContinuation: AsyncStream<Change>.Continuation!
        self.changes = AsyncStream { c in localContinuation = c }
        Task { await self.setContinuation(localContinuation) }
    }

    private func setContinuation(_ c: AsyncStream<Change>.Continuation) {
        self.continuation = c
    }

    func subscribe() async {
        guard channel == nil else { return }
        let ch = client.realtimeV2.channel("event-attendance-\(eventId.uuidString)")

        let insertChanges = ch.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "event_attendance",
            filter: "event_id=eq.\(eventId.uuidString.lowercased())"
        )
        let updateChanges = ch.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "event_attendance",
            filter: "event_id=eq.\(eventId.uuidString.lowercased())"
        )
        let deleteChanges = ch.postgresChange(
            DeleteAction.self,
            schema: "public",
            table: "event_attendance",
            filter: "event_id=eq.\(eventId.uuidString.lowercased())"
        )

        await ch.subscribe()
        channel = ch

        // Spin up consumers — one task per change kind, all yielding to the
        // same continuation.
        Task { [weak self] in
            for await action in insertChanges {
                guard let self else { return }
                await self.handleInsertOrUpdate(action.record)
            }
        }
        Task { [weak self] in
            for await action in updateChanges {
                guard let self else { return }
                await self.handleInsertOrUpdate(action.record)
            }
        }
        Task { [weak self] in
            for await action in deleteChanges {
                guard let self else { return }
                await self.handleDelete(action.oldRecord)
            }
        }
    }

    func unsubscribe() async {
        await channel?.unsubscribe()
        channel = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Decoders

    private func handleInsertOrUpdate(_ record: [String: AnyJSON]) async {
        guard let rsvp = decodeRSVP(record) else {
            log.warning("could not decode RSVP from record: \(String(describing: record))")
            return
        }
        continuation?.yield(.upsert(rsvp))
    }

    private func handleDelete(_ oldRecord: [String: AnyJSON]) async {
        guard let idString = oldRecord["id"]?.stringValue,
              let id = UUID(uuidString: idString)
        else {
            log.warning("delete record missing id")
            return
        }
        continuation?.yield(.delete(rsvpId: id))
    }

    private func decodeRSVP(_ record: [String: AnyJSON]) -> RSVP? {
        // Realtime payloads are AnyJSON dicts; re-encode → decode through
        // JSONDecoder using the same Codable + CodingKeys we use in the
        // repo. Cheaper than building a hand-decoder.
        do {
            let data = try JSONSerialization.data(withJSONObject: record.toFoundation())
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RSVP.self, from: data)
        } catch {
            log.warning("decode failed: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - AnyJSON helpers

private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

private extension Dictionary where Key == String, Value == AnyJSON {
    /// Convert AnyJSON dict back to a Foundation-compatible dict so
    /// JSONSerialization can re-encode it for Codable.decode.
    func toFoundation() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in self {
            out[k] = v.toFoundationValue()
        }
        return out
    }
}

private extension AnyJSON {
    func toFoundationValue() -> Any {
        switch self {
        case .null:           return NSNull()
        case .bool(let b):    return b
        case .integer(let i): return i
        case .double(let d):  return d
        case .string(let s):  return s
        case .array(let a):   return a.map { $0.toFoundationValue() }
        case .object(let o):  return o.toFoundation()
        }
    }
}
