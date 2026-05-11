import SwiftUI
import RuulUI
import RuulCore

/// RSVP roll for event-shaped resources. V1 renders a compact tally —
/// "Vas / Quizás / No vas / Pendiente" counts — when the rsvp capability
/// is enabled. Stateful interaction (tap to RSVP) routes back to the
/// legacy EventDetailCoordinator for now; we'll fold that into the
/// universal detail when the EventDetailView migration lands.
public struct RSVPSectionView: View {
    @Environment(AppState.self) private var app
    public let context: ResourceDetailContext
    @State private var rsvps: [RSVP] = []
    @State private var isLoading: Bool = true

    public static let definition = CapabilitySection(
        id: "rsvp",
        priority: 200,
        isEnabledFor: { caps in caps.contains("rsvp") },
        render: { ctx in AnyView(RSVPSectionView(context: ctx)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionHeader("RSVP")
            content
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack { Spacer(); ProgressView().padding(RuulSpacing.lg); Spacer() }
                .cardBackground()
        } else if rsvps.isEmpty {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Aún nadie ha confirmado")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Spacer()
            }
            .padding(RuulSpacing.md)
            .cardBackground()
        } else {
            VStack(spacing: 0) {
                tallyRow(.going,      label: "Vas",            color: .ruulPositive)
                divider
                tallyRow(.maybe,      label: "Quizás",         color: .ruulWarning)
                divider
                tallyRow(.declined,   label: "No vas",         color: .ruulNegative)
                divider
                tallyRow(.pending,    label: "Pendiente",      color: .ruulTextTertiary)
            }
            .cardBackground()
        }
    }

    private func tallyRow(_ status: RSVPStatus, label: String, color: Color) -> some View {
        let count = rsvps.filter { $0.status == status }.count
        return HStack(spacing: RuulSpacing.sm) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
            Text("\(count)")
                .ruulTextStyle(RuulTypography.statSmall)
                .foregroundStyle(Color.ruulTextSecondary)
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
    }

    private var divider: some View {
        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        do {
            rsvps = try await app.rsvpRepo.rsvps(for: context.resource.id)
        } catch {
            rsvps = []
        }
    }
}
