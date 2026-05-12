import SwiftUI
import RuulUI
import RuulCore

/// Renders schedule + recurrence info for any resource whose payload
/// contains a `startsAt` or `series_id`. V1 surfaces:
///   - Next occurrence (formatted relative)
///   - Recurrence pattern human label ("Cada jueves a las 8pm")
///   - "Parte de serie" badge when series_id is set
///
/// Driven by the `schedule` or `recurrence` capability. Events have
/// `schedule` baked in even when recurrence is off (single-shot event
/// still has a start time to display).
public struct ScheduleSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "schedule",
        priority: 100,
        isEnabledFor: { caps in
            caps.contains("schedule") || caps.contains("recurrence")
        },
        render: { ctx in AnyView(ScheduleSectionView(context: ctx)) }
    )

    public var body: some View {
        // Events show their schedule in the `EventHeroTitleBlock` (date
        // line + countdown + recurring pill). Repeating the same info
        // here as a "CUÁNDO" card just doubles the visual noise — hide
        // for events. Non-event resources still get the section.
        if !context.usesEventHero {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("Cuándo")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .padding(.horizontal, RuulSpacing.xxs)

                VStack(spacing: 0) {
                    if let starts = startsAt {
                        row(icon: "calendar", label: dateLabel(starts), trailing: relativeLabel(starts))
                        if recurrenceLabel != nil { divider }
                    }
                    if let recurrence = recurrenceLabel {
                        row(icon: "arrow.triangle.2.circlepath", label: "Recurrente", trailing: recurrence)
                    }
                }
                .cardBackground()
            }
        }
    }

    private var startsAt: Date? {
        if case let .string(s)? = context.resource.metadata["starts_at"],
           let d = ruulISO8601Date(from: s) {
            return d
        }
        if case let .string(s)? = context.resource.metadata["startsAt"],
           let d = ruulISO8601Date(from: s) {
            return d
        }
        return nil
    }

    private var recurrenceLabel: String? {
        // ResourceRow doesn't surface series_id yet — Phase 2 will add it.
        // For now infer recurrence from the "recurrence" capability being
        // enabled on this resource.
        if context.enabledCapabilities.contains("recurrence") {
            return "Parte de una serie"
        }
        return nil
    }

    private func dateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)    { return "Hoy · \(date.ruulShortTime)" }
        if cal.isDateInTomorrow(date) { return "Mañana · \(date.ruulShortTime)" }
        return "\(date.ruulShortDate) · \(date.ruulShortTime)"
    }

    private func relativeLabel(_ date: Date) -> String {
        date.ruulRelativeDescription
    }

    @ViewBuilder
    private func row(icon: String, label: String, trailing: String) -> some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextSecondary)
                .frame(width: 24)
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Text(trailing)
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, 48)
    }
}

/// Per-call ISO8601 parser. Avoids the Sendable issue around a shared
/// `ISO8601DateFormatter` static (it has internal mutable state). The
/// allocation cost is negligible — this only runs when a resource's
/// metadata actually carries a `starts_at` string.
private func ruulISO8601Date(from string: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: string) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: string)
}

extension View {
    /// Standard surface treatment for a section's content card. Used by
    /// every section renderer + the zone views (Summary / Attention).
    /// Centralized so the section catalog can keep visual consistency
    /// without each renderer reinventing the wheel.
    @ViewBuilder
    func cardBackground() -> some View {
        self
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
    }
}

/// Shared section header style for the dynamic stack. Sectioned-uppercase
/// caps + tertiary text — keeps the page's visual cadence consistent.
/// MainActor-isolated because RuulUI typography extensions are MainActor.
@MainActor
@ViewBuilder
func sectionHeader(_ title: String, count: Int? = nil) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(title)
            .ruulTextStyle(RuulTypography.sectionLabel)
            .foregroundStyle(Color.ruulTextTertiary)
        Spacer()
        if let count {
            Text("\(count)")
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }
    .padding(.horizontal, RuulSpacing.xxs)
}
