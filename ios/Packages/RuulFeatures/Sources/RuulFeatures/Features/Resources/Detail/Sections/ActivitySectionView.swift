import SwiftUI
import RuulUI
import RuulCore

/// Resource-scoped activity feed. Queries `system_events` filtered to
/// `resource_id = context.resource.id` so each row is a real atom (event
/// closed, fine officialized, vote opened, rule changed, …).
///
/// Settings-style grouped list under a quiet sentence-case header — no
/// more shouty "ACTIVIDAD" caps, no card chrome on loading / empty
/// states (those collapse to a quiet inline message instead).
public struct ActivitySectionView: View {
    @Environment(AppState.self) private var app

    public let context: ResourceDetailContext

    @State private var events: [SystemEvent] = []
    @State private var isLoading: Bool = true

    public static let definition = CapabilitySection(
        id: "activity",
        priority: 900,
        tabId: "activity",
        // Always render — every resource has a history.
        isEnabledFor: { _ in true },
        render: { ctx in AnyView(ActivitySectionView(context: ctx)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            header
            content
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Actividad")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
            if !events.isEmpty {
                Text("\(events.count)")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: RuulSpacing.sm) {
                ProgressView()
                Text("Cargando…")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RuulSpacing.xxs)
            .padding(.vertical, RuulSpacing.sm)
        } else if events.isEmpty {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
                Text("Aún no hay actividad")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RuulSpacing.xxs)
            .padding(.vertical, RuulSpacing.sm)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(events.prefix(8).enumerated()), id: \.element.id) { idx, event in
                    activityRow(event)
                    if idx < min(7, events.count - 1) { divider }
                }
            }
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
            )
        }
    }

    private func activityRow(_ event: SystemEvent) -> some View {
        let presentation = HistoryItemPresentation(event: event, memberName: memberName(for: event))
        return HStack(spacing: RuulSpacing.md) {
            Image(systemName: presentation.icon)
                .ruulTextStyle(RuulTypography.labelSemibold)
                .foregroundStyle(toneColor(presentation.tone))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(event.occurredAt.ruulRelativeDescription)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    /// Resolves the actor's display name for the event by matching
    /// `event.memberId` (group_member UUID) against `context.memberDirectory`
    /// (keyed by user UUID). Falls back to nil so HistoryItemPresentation
    /// renders its "Alguien" default.
    private func memberName(for event: SystemEvent) -> String? {
        guard let memberId = event.memberId else { return nil }
        return context.memberDirectory.values
            .first(where: { $0.member.id == memberId })
            .map { $0.displayName }
    }

    /// Maps HistoryItemPresentation tone to the design-token color used
    /// for the icon in the compact section row.
    private func toneColor(_ tone: RuulTimelineItem.Tone) -> Color {
        switch tone {
        case .positive: return Color.ruulPositive
        case .negative: return Color.ruulNegative
        case .warning:  return Color.ruulWarning
        case .info:     return Color.ruulAccent
        case .neutral:  return Color.ruulTextSecondary
        }
    }

    private var divider: some View {
        Divider()
            .background(Color.ruulSeparator)
            .padding(.leading, RuulSpacing.md + 28 + RuulSpacing.md)
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        let groupStream = (try? await app.systemEventRepo.recent(
            groupId: context.group.id,
            limit: 200
        )) ?? []
        events = groupStream.filter { $0.resourceId == context.resource.id }
    }
}
