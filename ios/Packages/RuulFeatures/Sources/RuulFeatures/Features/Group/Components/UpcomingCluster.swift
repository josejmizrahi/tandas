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

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text("Próximo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                if let onSeeAll {
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
                DateTile(date: item.occursAt, accent: accentColor)

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

                    HStack(spacing: RuulSpacing.xxs) {
                        Text(item.occursAt, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .monospacedDigit()
                        if let sub = subtitle {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                            Text(sub)
                                .font(.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
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

    private var subtitle: String? {
        switch item {
        case .event(let e):
            return primaryVenue(e.locationName)
        case .voteClosing:
            return "Cierra"
        case .slotRotation(_, _, _):
            return nil
        }
    }

    /// Subtle badge to indicate non-event upcoming items at a glance.
    /// Events get the recurring arrow when they're part of a series;
    /// votes get a checkmark.square; slots get a person.2.
    private var badgeIcon: String? {
        switch item {
        case .event(let e):
            return e.seriesId != nil ? "arrow.triangle.2.circlepath" : nil
        case .voteClosing:
            return "checkmark.square"
        case .slotRotation:
            return "person.2.fill"
        }
    }

    /// Accent color used in the DateTile's month label. Lets the
    /// founder distinguish row types at a glance without breaking the
    /// minimalist row design.
    private var accentColor: Color {
        switch item {
        case .event:        return .ruulSemanticError
        case .voteClosing:  return .ruulAccent
        case .slotRotation: return .ruulSemanticWarning
        }
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
