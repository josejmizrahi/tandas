import Foundation
import RuulCore
import RuulUI

/// Bridge for rendering `SystemEvent` rows inside resource details via
/// the universal `ActivityItem` model. Doctrine v2 §5 (Activity feed
/// obligatoria en TODA detail surface): Rule/Slot/Space/Fine previously
/// had no activity feed; this helper closes the gap by reusing the
/// same `HistoryItemPresentation` decoder the home cluster + ActivityView
/// + MemberDetailView already use.
///
/// Resolves actor names via a `[UUID: MemberWithProfile]` directory keyed
/// by `group_members.id`. Missing members render as "Alguien" inside the
/// presenter — no UI break.
enum SystemEventToActivityItem {
    static func map(
        _ events: [SystemEvent],
        members: [UUID: MemberWithProfile]
    ) -> [ActivityItem] {
        events.map { event in
            let actorName = event.memberId.flatMap { members[$0]?.displayName }
            let presentation = HistoryItemPresentation(
                event: event,
                memberName: actorName
            )
            return ActivityItem(
                id: event.id.uuidString,
                title: presentation.title,
                subtitle: presentation.subtitle,
                timestamp: event.occurredAt,
                icon: presentation.icon,
                kind: kind(for: presentation.tone),
                prebakedRelativeTime: presentation.timestamp
            )
        }
    }

    private static func kind(for tone: RuulTimelineItem.Tone) -> ActivityKind {
        switch tone {
        case .neutral, .info: return .neutral
        case .positive:       return .positive
        case .negative:       return .negative
        case .warning:        return .warning
        }
    }
}
