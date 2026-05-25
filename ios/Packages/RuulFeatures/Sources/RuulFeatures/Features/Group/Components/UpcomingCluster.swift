import SwiftUI
import RuulUI
import RuulCore

/// "Próximo" — cluster #2 de la doctrina situacional. PR-1 es
/// event-only; cuando se agreguen bookings polimórficos (slot/space)
/// el cluster los absorbe sin cambiar nombre ni posición. Cap a 5
/// rows para mantener el home tight.
@MainActor
struct UpcomingCluster: View {
    let events: [Event]
    let onOpenEvent: (Event) -> Void
    var onSeeAll: (() -> Void)?

    private var visible: [Event] {
        Array(events.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text("Próximo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer()
                if let onSeeAll {
                    Button("Ver todo", action: onSeeAll)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            .padding(.horizontal, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(visible) { event in
                    UpcomingRow(event: event, onTap: { onOpenEvent(event) })
                    if event.id != visible.last?.id {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 78)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
    }
}

@MainActor
private struct UpcomingRow: View {
    let event: Event
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: RuulSpacing.md) {
                DateTile(date: event.startsAt)

                VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                    HStack(spacing: RuulSpacing.xxs) {
                        Text(event.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ruulTextPrimary)
                            .lineLimit(2)
                        if event.seriesId != nil {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.ruulTextTertiary)
                                .accessibilityLabel("Recurrente")
                        }
                    }

                    HStack(spacing: RuulSpacing.xxs) {
                        Text(event.startsAt, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                            .monospacedDigit()
                        if let venue = primaryVenue(event.locationName) {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                            Text(venue)
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

    /// Mirrors `HomeOverviewView.UpcomingCard.primaryVenue` — toma el
    /// primer segmento antes de coma para no cortar mid-word
    /// ("Altezza Bosques, Camino a Tecamachalco 98" → "Altezza Bosques").
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

    var body: some View {
        VStack(spacing: RuulSpacing.s0_5) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.ruulSemanticError)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(date, format: .dateTime.day())
                .font(.title.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .frame(width: 50, height: 50)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}
