import SwiftUI
import RuulUI
import RuulCore

/// "Summary" zone for event-shaped resources per the canonical Resource
/// Detail spec — a compact magazine block of two-to-three status lines:
///
///   ⭐ Daniel hosting
///   👥 4 de 8 confirmados
///   📍 Casa de Jose
///
/// Replaces `DetailSummaryView`'s metadata-row card (host, lugar, capacidad,
/// dura, empieza) for events. The hero already carries the date / countdown
/// / status pills, so Summary sticks to who-and-where rather than fact dump.
public struct EventStatusSummary: View {
    @Environment(\.eventInteractor) private var interactor: (any EventInteractor)?

    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let host = hostName {
                row(icon: "person.fill", text: "\(host) está hospedando")
            }
            row(icon: "person.3.fill", text: attendingLine)
            if let location = locationName {
                row(icon: "mappin.and.ellipse", text: location)
            }
        }
        .padding(.horizontal, RuulSpacing.xxs)
    }

    // MARK: - Lines

    private func row(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ruulTextTertiary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived

    private var hostName: String? {
        guard let hostId = interactor?.event.hostId
            ?? context.resource.metadata["host_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        else { return nil }
        return context.memberDirectory[hostId]?.displayName
    }

    private var attendingLine: String {
        let going = interactor?.rsvps
            .filter { $0.status == .going }
            .reduce(0) { $0 + 1 + $1.plusOnes } ?? 0
        let capacityMax = interactor?.event.capacityMax
            ?? context.resource.metadata["capacity_max"]?.intValue
        if let capacityMax {
            return "\(going) de \(capacityMax) confirmados"
        }
        if going == 0 {
            return "Sin confirmaciones aún"
        }
        return going == 1 ? "1 confirmado" : "\(going) confirmados"
    }

    private var locationName: String? {
        let raw = interactor?.event.locationName
            ?? context.resource.metadata["location_name"]?.stringValue
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
