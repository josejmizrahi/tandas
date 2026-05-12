import SwiftUI
import RuulUI
import RuulCore

/// Capacity progress widget for event-shaped resources. Renders the
/// "X DE Y" header + RuulProgressBar fill + "LLENO" pill when the
/// resource has a `capacity_max` set. Gated by the `capacity` capability
/// (seeded for events by mig 00110). Returns `EmptyView` when the
/// metadata key is absent so the always-on cap stays harmless for
/// uncapped events.
///
/// Read counts come from `\.eventInteractor` when available — the live
/// rsvps list keeps the bar in sync with the realtime stream. Falls
/// back to a metadata-only render (no count) when no interactor is
/// scoped (read-only surfaces like ResourceDetailSheet).
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
        if let capacityMax {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 4) {
                        Text("\(seatsTaken)")
                            .ruulTextStyle(RuulTypography.statMedium)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("DE \(capacityMax)")
                            .ruulTextStyle(RuulTypography.sectionLabel)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                    Spacer()
                    if seatsTaken >= capacityMax {
                        HStack(spacing: RuulSpacing.xs) {
                            Circle()
                                .fill(Color.ruulNegative)
                                .frame(width: 8, height: 8)
                            Text("LLENO")
                                .ruulTextStyle(RuulTypography.sectionLabel)
                                .foregroundStyle(Color.ruulTextPrimary)
                        }
                        .accessibilityLabel("Cupo lleno")
                    }
                }
                RuulProgressBar(value: ratio)
                    .accessibilityLabel("Cupo")
                    .accessibilityValue("\(seatsTaken) de \(capacityMax)")
            }
        }
    }

    // MARK: - Data

    private var capacityMax: Int? {
        context.resource.metadata["capacity_max"]?.intValue
            ?? context.resource.metadata["capacityMax"]?.intValue
    }

    /// Sum of going seats (1 + plus_ones each) from the interactor's
    /// realtime list. Falls back to 0 when no interactor is in scope —
    /// the bar still draws so the cap is communicated.
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
