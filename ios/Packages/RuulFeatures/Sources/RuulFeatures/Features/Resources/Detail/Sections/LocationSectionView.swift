import SwiftUI
import MapKit
import RuulUI
import RuulCore

/// Location card section for resources with a physical place. Reuses
/// the existing `EventLocationCard` component (map preview + open-maps
/// CTA) so the visual treatment matches the legacy EventDetailView
/// titleBlock 1:1.
///
/// Gated by the `location` capability (seeded for every event by mig
/// 00110). Returns `EmptyView` when `metadata.location_name` is missing
/// or empty so the always-on capability doesn't pollute the page with
/// blank cards.
public struct LocationSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "location",
        priority: 120,
        isEnabledFor: { caps in caps.contains("location") },
        render: { ctx in AnyView(LocationSectionView(context: ctx)) }
    )

    public var body: some View {
        if let name = locationName {
            EventLocationCard(
                locationName: name,
                coordinate: coordinate,
                onOpenMaps: openMaps
            )
        }
    }

    // MARK: - Data

    private var locationName: String? {
        let raw = context.resource.metadata["location_name"]?.stringValue
            ?? context.resource.metadata["locationName"]?.stringValue
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var coordinate: CLLocationCoordinate2D? {
        let lat = decimal(metadata: context.resource.metadata, keys: ["location_lat", "locationLat"])
        let lng = decimal(metadata: context.resource.metadata, keys: ["location_lng", "locationLng"])
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private func decimal(metadata: JSONConfig, keys: [String]) -> Double? {
        for key in keys {
            guard let value = metadata[key] else { continue }
            switch value {
            case .double(let d):
                return d
            case .int(let i):
                return Double(i)
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Map handoff

    private func openMaps() {
        guard let name = locationName else { return }
        if let coordinate {
            let placemark = MKPlacemark(coordinate: coordinate)
            let mapItem = MKMapItem(placemark: placemark)
            mapItem.name = name
            mapItem.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
            ])
            return
        }
        // No coords — fall back to a search query.
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://maps.apple.com/?q=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }
}
