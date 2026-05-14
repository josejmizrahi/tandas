import SwiftUI
import MapKit
import CoreLocation
import RuulUI
import RuulCore

/// Apple Invites / Luma signature: an inline map snapshot with a pin and the
/// location address overlaid below. Tapping anywhere opens Apple Maps in
/// directions mode. Falls back to a slim row when the event has only a name
/// (no coords), so user can still tap to search.
public struct EventLocationCard: View {
    public let locationName: String
    public let coordinate: CLLocationCoordinate2D?
    public let onOpenMaps: () -> Void

    public init(locationName: String, coordinate: CLLocationCoordinate2D?, onOpenMaps: @escaping () -> Void) {
        self.locationName = locationName
        self.coordinate = coordinate
        self.onOpenMaps = onOpenMaps
    }

    public var body: some View {
        Button(action: onOpenMaps) {
            VStack(alignment: .leading, spacing: 0) {
                if let coordinate {
                    mapView(coordinate: coordinate)
                }
                addressRow
                    .padding(RuulSpacing.md)
            }
            .background(Color.ruulBackgroundRecessed)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.ruulPress)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ubicación: \(locationName). Tocá para abrir en Mapas")
    }

    private func mapView(coordinate: CLLocationCoordinate2D) -> some View {
        Map(
            initialPosition: .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                )
            ),
            interactionModes: []  // non-interactive — taps go to the wrapping Button
        ) {
            Marker(locationName, coordinate: coordinate)
                .tint(Color.ruulTextPrimary)
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .frame(height: 160)
        .allowsHitTesting(false)
    }

    private var addressRow: some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "mappin.and.ellipse")
                .ruulTextStyle(RuulTypography.subheadSemibold)
                .foregroundStyle(Color.ruulTextPrimary)
                .frame(width: 32, height: 32)
                .background(Color.ruulSurface, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(locationName)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("CÓMO LLEGAR")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .ruulTextStyle(RuulTypography.labelSemibold)
                .foregroundStyle(Color.ruulTextTertiary)
                .accessibilityHidden(true)
        }
    }
}
