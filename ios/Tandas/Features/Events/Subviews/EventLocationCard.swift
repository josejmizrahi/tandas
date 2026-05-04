import SwiftUI
import MapKit
import CoreLocation

/// Apple Invites / Luma signature: an inline map snapshot with a pin and the
/// location address overlaid below. Tapping anywhere opens Apple Maps in
/// directions mode. Falls back to a slim row when the event has only a name
/// (no coords), so user can still tap to search.
struct EventLocationCard: View {
    let locationName: String
    let coordinate: CLLocationCoordinate2D?
    let onOpenMaps: () -> Void

    var body: some View {
        Button(action: onOpenMaps) {
            VStack(alignment: .leading, spacing: 0) {
                if let coordinate {
                    mapView(coordinate: coordinate)
                }
                addressRow
                    .padding(RuulSpacing.s4)
            }
            .background(Color.ruulBackgroundRecessed)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 0.5)
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
        HStack(spacing: RuulSpacing.s3) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ruulTextPrimary)
                .frame(width: 32, height: 32)
                .background(Color.ruulBackgroundElevated, in: Circle())
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ruulTextTertiary)
        }
    }
}
