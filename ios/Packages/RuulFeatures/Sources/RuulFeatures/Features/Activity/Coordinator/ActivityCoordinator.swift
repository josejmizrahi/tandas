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
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "history")

    private static let pageSize = 50

    public var filter: SystemEventFilter
    public var events: [SystemEvent] = []
    public var isLoading: Bool = false
    public var hasMore: Bool = true
    public var error: CoordinatorError?
    /// Active group members keyed by `group_members.id`. Populated by
    /// `loadMembers()`; consumed by `ActivityView` via
    /// `actorName(for:)`. Empty during initial render — the feed
    /// renders with "Alguien" until the load completes (one round
    /// trip to `membersWithProfiles`).
    public var memberDirectoryByMemberId: [UUID: MemberWithProfile] = [:]

    public init(
        groupId: UUID,
        repo: any SystemEventRepository,
        groupsRepo: (any GroupsRepository)? = nil
    ) {
        self.groupId = groupId
        self.repo = repo
        self.groupsRepo = groupsRepo
        self.filter = SystemEventFilter(groupId: groupId)
    }

    public func refresh() async {
        events = []
        hasMore = true
        error = nil
        // Members + events in parallel — neither depends on the other.
        async let membersTask: Void = loadMembers()
        async let eventsTask: Void = loadMore()
        _ = await (membersTask, eventsTask)
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

    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repo.query(filter: filter, limit: Self.pageSize, offset: events.count)
            events.append(contentsOf: page)
            if page.count < Self.pageSize { hasMore = false }
        } catch {
            log.error("loadMore failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar la historia")
        }
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
