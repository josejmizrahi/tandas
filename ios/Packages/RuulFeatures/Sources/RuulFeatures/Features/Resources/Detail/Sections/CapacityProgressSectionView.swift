import SwiftUI
import RuulUI
import RuulCore

/// Compact capacity widget. Renders a single-line "X de Y · LLENO" caption
/// plus a thin progress bar — no big stat number, no cards-on-cards. Quiet
/// by design so it can sit in the page rhythm without competing with the
/// hero title block above.
///
/// Gated by the `capacity` capability (seeded for events by mig 00110)
/// and a non-nil `metadata.capacity_max`. Seat counts come from the
/// live `\.eventInteractor.rsvps` stream when in scope; falls back to
/// 0 when no interactor is present (preview / read-only surfaces).
public struct CapacityProgressSectionView: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?

    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "capacity_progress",
        priority: 110,
        isEnabledFor: { caps in caps.contains("capacity") },
        render: { ctx in AnyView(CapacityProgressSectionView(context: ctx)) }
    )

    public var body: some View {
        // For events, `ResourceSummaryView` already surfaces "X de Y
        // confirmados" textually. Repeating the same count as a bar here
        // would just thicken the rhythm without adding info. Other resource
        // types still get the visual bar.
        if context.resource.resourceType == .event {
            EmptyView()
        } else if let capacityMax {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: RuulSpacing.xs) {
                    Text(captionLine(capacityMax: capacityMax))
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                    Spacer(minLength: 0)
                    if seatsTaken >= capacityMax {
                        Text("LLENO")
                            .ruulTextStyle(RuulTypography.sectionLabel)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
                RuulProgressBar(value: ratio)
                    .accessibilityLabel("Cupo")
                    .accessibilityValue("\(seatsTaken) de \(capacityMax)")
            }
            .padding(.horizontal, RuulSpacing.xxs)
        }
    }

    private func captionLine(capacityMax: Int) -> String {
        "\(seatsTaken) de \(capacityMax) lugares"
    }

    private var capacityMax: Int? {
        context.resource.metadata["capacity_max"]?.intValue
            ?? context.resource.metadata["capacityMax"]?.intValue
    }

    private var seatsTaken: Int {
        guard let interactor else { return 0 }
        return interactor.rsvps
            .filter { $0.status == .going }
            .reduce(0) { $0 + 1 + $1.plusOnes }
    }

    private var ratio: Double {
        guard let capacityMax, capacityMax > 0 else { return 0 }
        return min(1, Double(seatsTaken) / Double(capacityMax))
    }
}
