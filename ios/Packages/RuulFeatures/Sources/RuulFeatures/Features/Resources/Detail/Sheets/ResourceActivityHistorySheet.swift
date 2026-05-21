import SwiftUI
import RuulCore
import RuulUI

/// Resource-scoped Activity history sheet — wired to the "Ver más"
/// affordance on `ActivityFeedView`. The detail page's Activity layer
/// shows the first 5 entries inline; this sheet pulls a longer window
/// when the user taps through.
///
/// Distinct from `MyTimelineView` (cross-group, user-scoped). This is
/// per-resource and shared by every host (`EventDetailHost`,
/// `ResourceDetailSheet`, `FineDetailHost`, `VoteDetailHost`).
///
/// Reads from `ActivityFeedLoader` so the row shape stays identical to
/// the inline feed — doctrine guard: human-readable sentences only,
/// never raw `system_events` strings.
@MainActor
public struct ResourceActivityHistorySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let resourceId: UUID
    public let displayName: String

    @State private var entries: [ActivityEntry] = []
    @State private var isLoading: Bool = true

    /// Wider window than the inline feed (5). 100 covers most resources
    /// without paying for pagination plumbing on first ship.
    private static let pageSize = 100

    public init(groupId: UUID, resourceId: UUID, displayName: String) {
        self.groupId = groupId
        self.resourceId = resourceId
        self.displayName = displayName
    }

    public var body: some View {
        NavigationStack {
            content
                .ruulSheetToolbar(displayName)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label("Sin actividad", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Aún no hay actividad registrada para este recurso.")
            }
        } else {
            List {
                Section("Historial") {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: RuulSpacing.sm) {
                            Text(entry.relativeTime)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(entry.sentence)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func load() async {
        let result = await ActivityFeedLoader.load(
            app: app,
            groupId: groupId,
            resourceId: resourceId,
            limit: Self.pageSize
        )
        entries = result.entries
        isLoading = false
    }
}
