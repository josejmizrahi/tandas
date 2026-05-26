import SwiftUI
import RuulUI
import RuulCore

/// "Próximo" — cluster #2 de la doctrina situacional. V2 (2026-05-25):
/// polimórfico sobre `UpcomingItem` (event / voteClosing / slotRotation
/// hoy; bookings / fine grace / asset return cuando el backend exponga
/// sus deadlines). Cap a 5 rows.
@MainActor
struct UpcomingCluster: View {
    let items: [UpcomingItem]
    let onOpenEvent: (Event) -> Void
    let onOpenVote: (Vote) -> Void
    let onOpenSlot: (Slot) -> Void
    var onSeeAll: (() -> Void)?

    private var visible: [UpcomingItem] {
        Array(items.prefix(5))
    }

    /// 2026-05-25 founder fix: "Ver todo" routes to `GroupEventsListView`
    /// (events-only directory). When Próximo currently surfaces ONLY
    /// non-event items (votes / slots), the user tap landed on an empty
    /// "Sin eventos" state — misleading. Hide the link entirely when
    /// the cluster has no events. When events ARE present, the link
    /// still routes to event history; a polymorphic
    /// `UpcomingItemsListView` is deferred.
    private var hasAnyEvent: Bool {
        items.contains { if case .event = $0 { return true }; return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text("Próximo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                if hasAnyEvent, let onSeeAll {
                    Button("Ver todo", action: onSeeAll)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            .padding(.horizontal, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(visible) { item in
                    UpcomingRow(item: item, onTap: { tap(item) })
                    if item.id != visible.last?.id {
                        Divider()
                            .background(Color.ruulTextTertiary.opacity(0.3))
                            .padding(.leading, 78)
                    }
                }
            }
            .ruulCardSurface(.solid)
        }
    }

    private func tap(_ item: UpcomingItem) {
        switch item {
        case .event(let e):                  onOpenEvent(e)
        case .voteClosing(let v):            onOpenVote(v)
        case .slotRotation(let s, _, _):     onOpenSlot(s)
        }
    }
}

// MARK: - Row

@MainActor
private struct UpcomingRow: View {
    let item: UpcomingItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.md) {
                leadingTile

                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    HStack(spacing: RuulSpacing.xxs) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ruulTextPrimary)
                            .lineLimit(2)
                        if let badge = badgeIcon {
                            Image(systemName: badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.ruulTextTertiary)
                                .accessibilityHidden(true)
                        }
                    }

                    if let sub = subtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Leading tile — type-appropriate

    /// 2026-05-25 founder fix: not every Próximo row deserves a
    /// calendar tile. Events ARE date-anchored (calendar feels right);
    /// votes and slots aren't (calendar implied "esto sucede en esa
    /// fecha" which is misleading). Polymorphic tile picks the right
    /// visual per case.
    @ViewBuilder
    private var leadingTile: some View {
        switch item {
        case .event:
            DateTile(date: item.occursAt, accent: accentColor)
        case .voteClosing:
            IconTile(systemName: "checkmark.square.fill", accent: accentColor)
        case .slotRotation:
            IconTile(systemName: "person.2.fill", accent: accentColor)
        }
    }

    // MARK: Per-case display

    private var title: String {
        switch item {
        case .event(let e):
            return e.title
        case .voteClosing(let v):
            return v.title
        case .slotRotation(_, let holder, let assetName):
            if let holder, let assetName { return "\(assetName) · \(holder)" }
            if let holder { return "Le toca a \(holder)" }
            if let assetName { return assetName }
            return "Turno asignado"
        }
    }

    /// Subtitle composition is now per-case (calendar tile only on
    /// events, so the time format used to live as a separate caption
    /// next to the venue — folding it into the subtitle keeps the row
    /// scan-readable across types).
    private var subtitle: String? {
        switch item {
        case .event(let e):
            let time = e.startsAt.formatted(.dateTime.hour().minute())
            if let venue = primaryVenue(e.locationName) {
                return "\(time) · \(venue)"
            }
            return time
        case .voteClosing(let v):
            return "Cierra \(relativeFutureLabel(v.closesAt))"
        case .slotRotation(let s, _, _):
            return startsAtLabel(s.startsAt)
        }
    }

    /// Subtle badge to indicate item kind at a glance.
    /// Events get the recurring arrow when part of a series; votes/slots
    /// get nothing extra (the leading IconTile already telegraphs the type).
    private var badgeIcon: String? {
        switch item {
        case .event(let e):
            return e.seriesId != nil ? "arrow.triangle.2.circlepath" : nil
        case .voteClosing, .slotRotation:
            return nil
        }
    }

    /// Accent color shared between the leading tile + (when used) the
    /// month label. Lets the user distinguish row kinds at a glance.
    private var accentColor: Color {
        switch item {
        case .event:        return .ruulSemanticError
        case .voteClosing:  return .ruulAccent
        case .slotRotation: return .ruulSemanticWarning
        }
    }

    /// Compact future-relative label for vote close deadlines.
    /// "en 4h", "hoy", "mañana", "el viernes", etc.
    private func relativeFutureLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "hoy" }
        if cal.isDateInTomorrow(date) { return "mañana" }
        let delta = date.timeIntervalSinceNow
        if delta < 3600 { return "en menos de 1h" }
        if delta < 86400 { return "en \(Int(delta / 3600))h" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: .now)
    }

    /// "Hoy 6pm" / "Mañana 8am" / "Vie 6pm".
    private func startsAtLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date)    { return "Hoy \(time)" }
        if cal.isDateInTomorrow(date) { return "Mañana \(time)" }
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        return "\(weekday) \(time)"
    }

    /// Mirrors `HomeOverviewView.UpcomingCard.primaryVenue` — toma el
    /// primer segmento antes de coma.
    private func primaryVenue(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let comma = raw.firstIndex(of: ",") {
            let head = raw[..<comma].trimmingCharacters(in: .whitespaces)
            return head.isEmpty ? raw : head
        }
        return raw
    }
}

@MainActor
private struct DateTile: View {
    let date: Date
    let accent: Color

    var body: some View {
        VStack(spacing: RuulSpacing.s0_5) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.caption2.weight(.bold))
                .foregroundStyle(accent)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(date, format: .dateTime.day())
                .font(.title.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .frame(width: 50, height: 50)
        .ruulCardSurface(.solid, radius: RuulRadius.md)
    }
}

/// 2026-05-25 sibling of `DateTile` for non-event upcoming items.
/// Same dimensions and surface so the row alignment stays consistent;
/// the icon + accent telegraph "this isn't a date-anchored event"
/// without breaking the visual rhythm of the cluster.
@MainActor
private struct IconTile: View {
    let systemName: String
    let accent: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(accent)
            .frame(width: 50, height: 50)
            .ruulCardSurface(.solid, radius: RuulRadius.md)
    }
}
