import Foundation
import Supabase

/// V2-A1 — subscribes to postgres-change streams scoped to a single
/// `group_id` on one of the three canonical surfaces (timeline /
/// disputes / decisions). The store wires the callback as a coarse
/// refresh trigger; raw row payloads are not decoded into domain
/// models because canonical reads come from pre-joined RPCs (display
/// names, my_vote, ...). RLS gates delivery; `REPLICA IDENTITY FULL`
/// on the published tables (mig 20260527235000) lets the publisher
/// re-evaluate `is_group_member(group_id, auth.uid())` against the
/// WAL row image.
public protocol GroupRealtimeService: Sendable {
    func subscribe(
        groupId: UUID,
        table: GroupRealtimeTable,
        onChange: @escaping @Sendable () async -> Void
    ) async -> any GroupRealtimeSubscription
}

public enum GroupRealtimeTable: String, Sendable, CaseIterable {
    case events    = "group_events"
    case disputes  = "group_disputes"
    case decisions = "group_decisions"
}

public protocol GroupRealtimeSubscription: Sendable {
    func cancel() async
}

/// Production implementation backed by `supabase-swift`'s realtime
/// channel client. Each call opens a distinct topic so the caller can
/// cancel one table's stream without affecting siblings. The channel
/// cache inside `RealtimeClientV2` dedupes on topic, so repeated
/// `subscribe(...)` calls with the same `(groupId, table)` reuse the
/// underlying WebSocket join.
public final class SupabaseGroupRealtimeService: GroupRealtimeService {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func subscribe(
        groupId: UUID,
        table: GroupRealtimeTable,
        onChange: @escaping @Sendable () async -> Void
    ) async -> any GroupRealtimeSubscription {
        let topic = "ruul:group:\(groupId.uuidString.lowercased()):\(table.rawValue)"
        let channel = client.realtime.channel(topic)
        let stream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: table.rawValue,
            filter: .eq("group_id", value: groupId)
        )
        await channel.subscribe()

        let task = Task {
            for await _ in stream {
                if Task.isCancelled { return }
                await onChange()
            }
        }
        return LiveSubscription(channel: channel, task: task)
    }

    private final class LiveSubscription: GroupRealtimeSubscription {
        let channel: RealtimeChannelV2
        let task: Task<Void, Never>

        init(channel: RealtimeChannelV2, task: Task<Void, Never>) {
            self.channel = channel
            self.task = task
        }

        func cancel() async {
            task.cancel()
            await channel.unsubscribe()
        }
    }
}

/// No-op implementation for previews / mock-only Xcode runs where
/// opening a real WebSocket against Supabase is undesirable.
public final class NoopGroupRealtimeService: GroupRealtimeService {
    public init() {}

    public func subscribe(
        groupId: UUID,
        table: GroupRealtimeTable,
        onChange: @escaping @Sendable () async -> Void
    ) async -> any GroupRealtimeSubscription {
        NoopSubscription()
    }

    private final class NoopSubscription: GroupRealtimeSubscription {
        func cancel() async {}
    }
}
