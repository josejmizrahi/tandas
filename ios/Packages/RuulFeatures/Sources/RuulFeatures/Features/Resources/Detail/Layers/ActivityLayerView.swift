import SwiftUI
import RuulCore
import RuulUI

/// Universal Resource Detail — **Activity layer**.
///
/// Answers the user's questions: *¿Qué pasó recientemente?* and
/// *¿Qué cambió?*
///
/// Thin wrapper around `ActivityFeedView` so the rest of the codebase
/// can refer to the layer by name. The wrapper renders nothing when
/// the feed is empty — matching the doctrine rule "Activity is
/// visible when there's any human-readable activity entry."
///
/// Doctrine guard (see `Plans/Active/Fase1ComponentMap.md`
/// §"Universal Resource Detail" → "Activity layer"): the strings here
/// must be human-readable sentences ("Linda agregó un gasto",
/// "José confirmó asistencia") — never raw `system_events` rows,
/// audit identifiers, or metadata diffs. That contract lives in the
/// builder + `ActivityFeedLoader`, not in this View.
@MainActor
struct ActivityLayerView: View {
    let entries: [ActivityEntry]
    let hasMore: Bool
    let onSeeMore: () -> Void

    var body: some View {
        ActivityFeedView(
            entries: entries,
            hasMore: hasMore,
            onSeeMore: onSeeMore
        )
    }
}
