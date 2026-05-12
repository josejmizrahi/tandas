import SwiftUI
import RuulUI
import RuulCore

/// Magazine-style title block for event-shaped resources. Replaces the
/// generic `DetailHeaderView` (icon badge + title + type label) with a
/// confident hero in the Apple Invites / Calendar mold:
///
///   - Tiny uppercase date line on top (HOY · 19:30 / MAR 11 MAY · 19:30)
///   - Display-large title that owns the visual weight
///   - Countdown affordance ("EMPIEZA EN 2 DÍAS") for upcoming events <7d out
///   - Status pill row (cancelled / closed / in-progress / recurring)
///
/// Pulls live state from `\.eventInteractor` so the title block reflects
/// the realtime event payload (status changes, edits land immediately).
/// Falls back to the snapshot from `context.resource` when no interactor
/// is scoped (preview-friendly, read-only surfaces).
public struct EventHeroTitleBlock: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?

    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.md) {
            // Date / status row — keeps the page anchored before the title.
            HStack(spacing: RuulSpacing.xs) {
                Text(dateLine)
                    .ruulTextStyle(RuulTypography.sectionLabelLg)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .accessibilityLabel("Fecha: \(dateLineAccessible)")
                Spacer()
                statusPills
            }

            Text(displayTitle)
                .ruulTextStyle(RuulTypography.displayLarge)
                .foregroundStyle(Color.ruulTextPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let countdown {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.ruulWarning)
                        .accessibilityHidden(true)
                    Text(countdown)
                        .ruulTextStyle(RuulTypography.sectionLabelLg)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    // MARK: - Derived state

    private var liveEvent: Event? { interactor?.event }

    private var displayTitle: String {
        liveEvent?.title ?? context.displayName
    }

    private var dateLine: String {
        guard let startsAt = liveEvent?.startsAt ?? startsAtFromMetadata else {
            return ""
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(startsAt) {
            return "HOY · \(startsAt.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(startsAt) {
            return "MAÑANA · \(startsAt.ruulShortTime)"
        }
        return "\(startsAt.ruulShortDate.uppercased()) · \(startsAt.ruulShortTime)"
    }

    /// VoiceOver-friendly variant of `dateLine`. Strips the bullet and
    /// uppercase so screen readers don't shout the chrome.
    private var dateLineAccessible: String {
        guard let startsAt = liveEvent?.startsAt ?? startsAtFromMetadata else {
            return ""
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(startsAt) {
            return "Hoy a las \(startsAt.ruulShortTime)"
        }
        if calendar.isDateInTomorrow(startsAt) {
            return "Mañana a las \(startsAt.ruulShortTime)"
        }
        return "\(startsAt.ruulShortDate) a las \(startsAt.ruulShortTime)"
    }

    private var startsAtFromMetadata: Date? {
        if let s = context.resource.metadata["starts_at"]?.stringValue,
           let d = parseISO(s) {
            return d
        }
        return nil
    }

    private var countdown: String? {
        guard let event = liveEvent, event.status == .upcoming else { return nil }
        let interval = event.startsAt.timeIntervalSince(.now)
        guard interval > 0 else { return nil }
        let days = Int(interval / 86_400)
        let hours = Int(interval / 3_600)
        let minutes = Int(interval / 60)
        if interval < 3_600 {
            return "EMPIEZA EN \(max(1, minutes)) MIN"
        }
        if interval < 86_400 {
            return "EMPIEZA EN \(hours) H"
        }
        if days < 7 {
            return days == 1 ? "EMPIEZA MAÑANA" : "EMPIEZA EN \(days) DÍAS"
        }
        return nil
    }

    @ViewBuilder
    private var statusPills: some View {
        if let event = liveEvent {
            HStack(spacing: RuulSpacing.xs) {
                switch event.status {
                case .inProgress:
                    pill("EN VIVO", dot: .ruulNegative)
                case .cancelled:
                    pill("CANCELADO", dot: .ruulNegative)
                case .closed:
                    pill("CERRADO", dot: .ruulTextSecondary)
                case .upcoming:
                    EmptyView()
                }
                if event.isRecurringGenerated {
                    pill("RECURRENTE", dot: .ruulAccent)
                }
            }
        }
    }

    private func pill(_ text: String, dot: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
            Text(text)
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
