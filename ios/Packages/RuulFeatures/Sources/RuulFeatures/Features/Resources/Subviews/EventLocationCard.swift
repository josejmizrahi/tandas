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
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
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
                .tint(Color.primary)
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .frame(height: 160)
        .allowsHitTesting(false)
    }

    private var addressRow: some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "mappin.and.ellipse")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
                .background(Color.ruulSurface, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(locationName)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("Cómo llegar")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
    }
}
