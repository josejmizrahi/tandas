import Foundation
import RuulCore

/// Shared activity feed loader for every detail host. Hits
/// `SystemEventRepository.query(filter:limit:offset:)` and humanizes the
/// resulting `system_events` rows into the universal `ActivityEntry`
/// shape that `UniversalResourceDetailView` renders inline at the
/// bottom of the page.
///
/// Per Addendum F: the View never touches Supabase. This loader is the
/// canonical adapter — hosts call it during block rebuild and pass the
/// returned entries into `ResourceBlocks.activityHead`.
///
/// Centralizing avoids the EventDetailHost-only wiring that left
/// Fund/Right/Asset/Fine/Vote shipping an empty feed.
enum ActivityFeedLoader {
    /// Fetches at most `limit` system_events for `resourceId` in
    /// `groupId`, sorted descending by `occurred_at`, and converts each
    /// to an `ActivityEntry`. Returns an empty array on any failure —
    /// activity is best-effort and must not block the rest of the
    /// page.
    @MainActor
    static func load(
        app: AppState,
        groupId: UUID,
        resourceId: UUID,
        limit: Int = 5
    ) async -> (entries: [ActivityEntry], hasMore: Bool) {
        let filter = SystemEventFilter(groupId: groupId, resourceId: resourceId)
        // Over-fetch by one so we can answer `hasMore` without a separate
        // count query — UI shows `limit` and the +1 row signals "see more
        // available" without paying for a `count(*)` round trip.
        let overFetch = limit + 1
        let events = (try? await app.systemEventRepo.query(
            filter: filter, limit: overFetch, offset: 0
        )) ?? []
        let hasMore = events.count > limit
        let entries = events.prefix(limit).map { ev in
            ActivityEntry(
                id: ev.id,
                sentence: ev.eventType.humanLabel,
                relativeTime: Self.relativeTime(from: ev.occurredAt),
                icon: nil   // Phase F follow-up: per-eventType SF Symbols
            )
        }
        return (Array(entries), hasMore)
    }

    /// Compact relative-time formatter used by every host's feed. Mirrors
    /// the EventDetailHost convention so the feed renders identically
    /// across resource families.
    static func relativeTime(from date: Date) -> String {
        let delta = Date.now.timeIntervalSince(date)
        if delta < 60       { return "hace un momento" }
        if delta < 3_600    { return "hace \(Int(delta / 60)) min" }
        if delta < 86_400   { return "hace \(Int(delta / 3_600))h" }
        if delta < 86_400 * 7 {
            return "hace \(Int(delta / 86_400)) d"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}
