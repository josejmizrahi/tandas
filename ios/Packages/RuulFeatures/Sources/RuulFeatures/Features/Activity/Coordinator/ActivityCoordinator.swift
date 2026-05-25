import Foundation
import Observation
import OSLog
import RuulCore
import RuulUI

/// Loads + paginates `SystemEvent`s for `ActivityView`. Holds the
/// active filter state; refilters by re-querying (no client-side
/// filtering — server does it).
///
/// Slice 11 added a group-members lookup so the activity feed can
/// render actor names ("Jose creó un derecho") instead of the generic
/// "Alguien". The directory is keyed by `group_members.id` because
/// that's what `SystemEvent.memberId` carries.
@Observable
@MainActor
public final class ActivityCoordinator {
    public let groupId: UUID
    private let repo: any SystemEventRepository
    private let groupsRepo: (any GroupsRepository)?
    private let resourceRepo: (any ResourceRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "history")

    private static let pageSize = 50

    public var filter: SystemEventFilter
    public var events: [SystemEvent] = []
    public var isLoading: Bool = false
    public var hasMore: Bool = true
    public var error: CoordinatorError?
    /// True once `refresh()`/`loadMore()` ha terminado al menos una vez.
    /// Permite distinguir "primera carga" de "loaded empty" en
    /// `LoadPhase.fromCollection` — antes `events == []` durante la
    /// primera carga colapsaba a `.empty` y mostraba el empty hero
    /// debajo del spinner.
    public private(set) var hasLoaded: Bool = false
    /// Active group members keyed by `group_members.id`. Populated by
    /// `loadMembers()`; consumed by `ActivityView` via
    /// `actorName(for:)`. Empty during initial render — the feed
    /// renders with "Alguien" until the load completes (one round
    /// trip to `membersWithProfiles`).
    public var memberDirectoryByMemberId: [UUID: MemberWithProfile] = [:]
    /// P5 (audit gap): resources keyed by id so `.ledgerEntryCreated`
    /// can resolve `payload.source_resource_id` → name in the feed
    /// ("Daniel registró $500 para Cena Shabbat"). Empty until first
    /// successful `loadResources()`; missing names degrade silently
    /// (the suffix just doesn't appear).
    public var resourceDirectoryById: [UUID: ResourceRow] = [:]

    /// Edit foundation (mig 00368/00369): the set of ledger_entry ids
    /// that have BEEN reversed (originals whose pair landed). Used by
    /// the feed to render "Revertido" badges + suppress the contextMenu
    /// on rows that can't be reversed again.
    public private(set) var reversedEntryIds: Set<UUID> = []
    /// The set of ledger_entry ids that ARE reverses (settlement rows
    /// emitted by `reverse_ledger_entry`). Used to hide their own
    /// "Revertir" action — reverses aren't themselves reversible.
    public private(set) var reverseEntryIds: Set<UUID> = []

    public init(
        groupId: UUID,
        repo: any SystemEventRepository,
        groupsRepo: (any GroupsRepository)? = nil,
        resourceRepo: (any ResourceRepository)? = nil
    ) {
        self.groupId = groupId
        self.repo = repo
        self.groupsRepo = groupsRepo
        self.resourceRepo = resourceRepo
        self.filter = SystemEventFilter(groupId: groupId)
    }

    public func refresh() async {
        events = []
        hasMore = true
        error = nil
        // Members + events in parallel — neither depends on the other.
        // Members es best-effort (no influye al phase); el primary signal
        // del coordinator es events, así que `hasLoaded` se marca al final
        // independiente de membersTask.
        async let membersTask: Void = loadMembers()
        async let resourcesTask: Void = loadResources()
        async let eventsTask: Void = loadMore()
        _ = await (membersTask, resourcesTask, eventsTask)
        hasLoaded = true
    }

    /// Adapter para `AsyncContentView`. El primary data son `events`;
    /// `memberDirectoryByMemberId` es best-effort (failures se loguean
    /// y la lista renderiza "Alguien" como actor).
    public var phase: LoadPhase<[SystemEvent]> {
        LoadPhase.fromCollection(
            value: events,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: error
        )
    }

    /// P5 (audit gap): one-shot resource load. Pulls every active
    /// resource type the group uses so `.ledgerEntryCreated` entries
    /// with `source_resource_id` can render the suffix "para X". 200
    /// is generous — most groups have <50 resources. Soft-fails.
    private func loadResources() async {
        guard resourceDirectoryById.isEmpty, let repo = resourceRepo else { return }
        do {
            let rows = try await repo.list(
                in: groupId,
                types: ResourceType.allCases,
                statuses: nil,
                limit: 200
            )
            resourceDirectoryById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        } catch {
            log.warning("loadResources failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-shot members load. Failures degrade silently (feed still
    /// renders, just without actor names) — the events feed is the
    /// primary signal; missing names is a cosmetic loss.
    private func loadMembers() async {
        guard memberDirectoryByMemberId.isEmpty, let groupsRepo else { return }
        do {
            let members = try await groupsRepo.membersWithProfiles(of: groupId)
            memberDirectoryByMemberId = Dictionary(
                uniqueKeysWithValues: members.map { ($0.member.id, $0) }
            )
        } catch {
            log.warning("loadMembers failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Display name for the actor of `event`, or nil when the event has
    /// no member_id or the member isn't in the directory. Callers fall
    /// back to "Alguien" when nil.
    public func actorName(for event: SystemEvent) -> String? {
        guard let memberId = event.memberId else { return nil }
        return memberDirectoryByMemberId[memberId]?.displayName
    }

    /// Avatar URL del actor para renderizar en RuulTimelineItem. nil
    /// cuando no hay member_id (events sintéticos como rsvpDeadlinePassed
    /// o hoursBeforeEvent) o el directory aún no se hidrató.
    public func actorAvatarURL(for event: SystemEvent) -> URL? {
        guard let memberId = event.memberId else { return nil }
        return memberDirectoryByMemberId[memberId]?.avatarURL
    }

    /// P2 (mig 00366): resolves any group_members.id to its display
    /// name. Used by `HistoryItemPresentation.ledgerEntryCreated` to
    /// surface "pagado por X" when the payload's paid_by_member_id
    /// differs from the actor. Returns nil when the id isn't in the
    /// directory (member left the group, or directory not yet loaded).
    public func memberName(forMemberId memberId: UUID) -> String? {
        memberDirectoryByMemberId[memberId]?.displayName
    }

    /// P5: resolves a resource id to its display name (from metadata.
    /// name when present). Used to surface "para Cena Shabbat" suffix
    /// in `.ledgerEntryCreated` titles when payload carries
    /// `source_resource_id`. Returns nil when the resource isn't in
    /// the loaded directory (archived, in another group, or just not
    /// yet hydrated) — caller drops the suffix gracefully.
    public func resourceName(forResourceId resourceId: UUID) -> String? {
        guard let row = resourceDirectoryById[resourceId] else { return nil }
        return row.metadata["name"]?.stringValue
    }

    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
            rebuildReversalIndex()
        }
        do {
            let page = try await repo.query(filter: filter, limit: Self.pageSize, offset: events.count)
            events.append(contentsOf: page)
            if page.count < Self.pageSize { hasMore = false }
        } catch {
            log.error("loadMore failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar la historia")
        }
    }

    /// Walks the loaded `events`, classifying each `ledgerEntryCreated`
    /// row into its reversal status:
    ///   - row carries `reversed_ledger_entry_id` → it IS a reverse
    ///   - row's `entry_id` matches some other row's
    ///     `reversed_ledger_entry_id` → it has BEEN reversed
    /// The two sets are mutually exclusive in practice (mig 00368 RPC
    /// rejects double-reverses and meta-reverses).
    ///
    /// Called from `loadMore()`'s defer block so the index is fresh on
    /// every page load. Cheap — single pass over `events`.
    private func rebuildReversalIndex() {
        var reversed: Set<UUID> = []
        var reverses: Set<UUID> = []
        for ev in events where ev.eventType == .ledgerEntryCreated {
            guard let entryIdStr = ev.payload["entry_id"]?.stringValue,
                  let entryId = UUID(uuidString: entryIdStr) else { continue }
            if let revStr = ev.payload["reversed_ledger_entry_id"]?.stringValue,
               let originalId = UUID(uuidString: revStr) {
                reverses.insert(entryId)
                reversed.insert(originalId)
            }
        }
        reversedEntryIds = reversed
        reverseEntryIds = reverses
    }

    public func clearError() { error = nil }

    public func setEventType(_ type: SystemEventType?) {
        filter.eventType = type
        Task { await refresh() }
    }

    public func setMember(_ memberId: UUID?) {
        filter.memberId = memberId
        Task { await refresh() }
    }

    public func setDateRange(from: Date?, to: Date?) {
        filter.fromDate = from
        filter.toDate = to
        Task { await refresh() }
    }

    public func clearFilters() {
        filter = SystemEventFilter(groupId: groupId)
        Task { await refresh() }
    }

    public var hasAnyFilter: Bool {
        filter.memberId != nil || filter.eventType != nil ||
        filter.resourceId != nil || filter.fromDate != nil || filter.toDate != nil
    }
}
