import Foundation
import OSLog

#if canImport(Supabase)
import Supabase
#endif

/// Cross-device sync feed for Beta 1 W3 item E-3.1.
///
/// When the same user is signed in on two devices (iPhone + iPad is the
/// pareja use case the founder cares about), changes one device commits
/// should propagate to the other without manual refresh:
///
/// - **Inbox** — device A resolves an action → device B clears the row.
/// - **Votes** — vote opens/resolves → both devices update.
/// - **Vote casts** — caster's other device updates the tally.
/// - **Fines** — paid / voided / appealed transitions sync.
///
/// Source of truth is the four Realtime-published tables (mig 00161).
/// The feed exposes a single `AsyncStream<Change>` so subscribers (mostly
/// coordinators) can react to "table X changed, refresh whatever you
/// cache". The feed deliberately yields *kicks*, not row payloads —
/// repositories already encode the read shape; coordinators re-fetch on
/// each kick rather than trying to decode realtime row deltas.
///
/// Authorization: the underlying Postgres publication is filterless, but
/// RLS evaluates on every dispatched WAL row. With REPLICA IDENTITY FULL
/// (mig 00161) the policies' qualifications on `user_id` / `group_id` /
/// `member_id` evaluate correctly and Supabase Realtime drops rows the
/// caller can't see. That means a single channel per table is enough —
/// no per-group filter wrangling on the client. RLS does the scoping.
public protocol MultiDeviceChangeFeed: Actor {
    /// Single stream of cross-device invalidation kicks. Yields once per
    /// realtime postgres_changes event the feed receives, after RLS has
    /// filtered to rows the user can read. Subscribers iterate in a Task
    /// and call their own `refresh()` on each tick.
    nonisolated var changes: AsyncStream<MultiDeviceChange> { get }

    /// Open channels for `user_actions`, `votes`, `vote_casts`, `fines`.
    /// Idempotent — second call is a no-op while channels are alive.
    /// Failure to connect (offline, server unreachable) is swallowed so
    /// callers can keep working via manual refresh + optimistic updates.
    func start() async

    /// Tear down all channels. Called on `AppState.signOut()` and from
    /// the live impl's `deinit`. Idempotent.
    func stop() async
}

/// One invalidation kick. `table` identifies which Realtime channel
/// fired; `recordId` is the row primary key so coordinators that key by
/// id can filter (e.g. `VoteDetailCoordinator` only cares if `recordId
/// == myVoteId`).
public struct MultiDeviceChange: Sendable, Equatable {
    public enum Table: String, Sendable, Equatable {
        case userAction
        case vote
        case voteCast
        case fine
    }

    public let table: Table
    public let recordId: UUID

    public init(table: Table, recordId: UUID) {
        self.table = table
        self.recordId = recordId
    }
}

// =============================================================================
// MockMultiDeviceChangeFeed
// =============================================================================

/// No-op feed for previews + tests. The `changes` stream never yields
/// unless callers explicitly feed it via `inject(_:)`. `start()` / `stop()`
/// are no-ops.
public actor MockMultiDeviceChangeFeed: MultiDeviceChangeFeed {
    public nonisolated let changes: AsyncStream<MultiDeviceChange>
    private let continuation: AsyncStream<MultiDeviceChange>.Continuation

    public init() {
        var localContinuation: AsyncStream<MultiDeviceChange>.Continuation!
        self.changes = AsyncStream { c in localContinuation = c }
        self.continuation = localContinuation
    }

    public func start() async {}
    public func stop() async {
        continuation.finish()
    }

    /// Test hook — feed a synthetic change through the stream.
    public func inject(_ change: MultiDeviceChange) {
        continuation.yield(change)
    }
}

// =============================================================================
// LiveMultiDeviceChangeFeed
// =============================================================================

#if canImport(Supabase)

/// Live feed backed by Supabase Realtime v2. Opens one channel per
/// published table (mig 00161) and fans every INSERT / UPDATE / DELETE
/// into the shared `changes` stream as a `MultiDeviceChange`.
///
/// Why a single shared stream instead of per-table streams: coordinators
/// already filter by table type via the `Change.table` discriminator;
/// keeping one stream means one Task per consumer, simpler lifecycle.
///
/// Why no group filter on the channel side: RLS does the scoping (mig
/// 00161 sets REPLICA IDENTITY FULL so RLS quals on non-PK columns
/// evaluate correctly). A user joining a new group mid-session
/// automatically sees that group's votes/fines without re-subscribing.
public actor LiveMultiDeviceChangeFeed: MultiDeviceChangeFeed {
    public nonisolated let changes: AsyncStream<MultiDeviceChange>

    private let client: SupabaseClient
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "realtime.multidevice")
    private let continuation: AsyncStream<MultiDeviceChange>.Continuation

    private var userActionChannel: RealtimeChannelV2?
    private var voteChannel:       RealtimeChannelV2?
    private var voteCastChannel:   RealtimeChannelV2?
    private var fineChannel:       RealtimeChannelV2?
    private var consumerTasks: [Task<Void, Never>] = []

    public init(client: SupabaseClient) {
        self.client = client
        var localContinuation: AsyncStream<MultiDeviceChange>.Continuation!
        self.changes = AsyncStream { c in localContinuation = c }
        self.continuation = localContinuation
    }

    deinit {
        continuation.finish()
    }

    public func start() async {
        guard userActionChannel == nil else { return }

        userActionChannel = await openChannel(
            name: "multidevice-user_actions",
            table: "user_actions",
            tableTag: .userAction
        )
        voteChannel = await openChannel(
            name: "multidevice-votes",
            table: "votes",
            tableTag: .vote
        )
        voteCastChannel = await openChannel(
            name: "multidevice-vote_casts",
            table: "vote_casts",
            tableTag: .voteCast
        )
        fineChannel = await openChannel(
            name: "multidevice-fines",
            table: "fines",
            tableTag: .fine
        )
    }

    public func stop() async {
        for task in consumerTasks { task.cancel() }
        consumerTasks.removeAll()
        await userActionChannel?.unsubscribe()
        await voteChannel?.unsubscribe()
        await voteCastChannel?.unsubscribe()
        await fineChannel?.unsubscribe()
        userActionChannel = nil
        voteChannel = nil
        voteCastChannel = nil
        fineChannel = nil
    }

    // MARK: - Channel plumbing

    private func openChannel(
        name: String,
        table: String,
        tableTag: MultiDeviceChange.Table
    ) async -> RealtimeChannelV2 {
        let channel = client.realtimeV2.channel(name)
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: table
        )
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: table
        )
        let deletes = channel.postgresChange(
            DeleteAction.self,
            schema: "public",
            table: table
        )

        // Spin consumers BEFORE subscribing so we never miss the first
        // dispatched row.
        consumerTasks.append(Task { [weak self] in
            for await action in inserts {
                await self?.yield(table: tableTag, record: action.record)
            }
        })
        consumerTasks.append(Task { [weak self] in
            for await action in updates {
                await self?.yield(table: tableTag, record: action.record)
            }
        })
        consumerTasks.append(Task { [weak self] in
            for await action in deletes {
                await self?.yield(table: tableTag, record: action.oldRecord)
            }
        })

        await channel.subscribe()
        return channel
    }

    private func yield(
        table: MultiDeviceChange.Table,
        record: [String: AnyJSON]
    ) {
        // Inlined .string-case unwrap. RSVPRealtimeService.swift has its
        // own file-scoped `AnyJSON.stringValue`; Swift's `private
        // extension` semantics make the extension members file-private
        // (Swift 6 hardens this), so we can't reuse it across files.
        // Trivial enough to inline rather than promote to internal.
        let idRaw: String?
        if case .string(let s) = record["id"] ?? .null { idRaw = s } else { idRaw = nil }
        guard let s = idRaw, let id = UUID(uuidString: s) else {
            log.warning("change for \(table.rawValue) missing id")
            return
        }
        continuation.yield(MultiDeviceChange(table: table, recordId: id))
    }
}

#endif
