import Foundation
import MapKit

/// Wraps `MKLocalSearchCompleter` for autocomplete in `LocationAutocompletePicker`.
/// Resolves a selected suggestion to a `CLPlacemark` (with lat/lng) on demand.
@MainActor @Observable
final class LocationSearchService: NSObject {
    var query: String = "" {
        didSet { completer.queryFragment = query }
    }
    private(set) var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Resolve a suggestion to coordinates. Returns nil on failure.
    func resolve(_ suggestion: MKLocalSearchCompletion) async -> (name: String, lat: Double, lng: Double)? {
        let request = MKLocalSearch.Request(completion: suggestion)
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            guard let item = response.mapItems.first else { return nil }
            let coord = item.placemark.coordinate
            let name = item.name ?? suggestion.title
            return (name, coord.latitude, coord.longitude)
        } catch {
            return nil
        }
    }
}

extension LocationSearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        nonisolated(unsafe) let results = completer.results
        Task { @MainActor in
            self.suggestions = results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestions = []
        }
    }
}
