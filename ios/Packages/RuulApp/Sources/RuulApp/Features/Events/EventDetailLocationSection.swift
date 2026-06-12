import SwiftUI
import MapKit
import RuulCore

// MARK: - F.EVENT.11 Ubicación (Section dedicada — mapa nativo + tap → Apple Maps)
//
// Apple Calendar muestra la ubicación con un snippet de mapa arriba de la
// dirección. El texto libre de `location_text` se resuelve vía MKLocalSearch
// (mismo motor que el autocomplete de CreateEventView); si la búsqueda no
// encuentra nada, la sección degrada en silencio a la fila de texto.

struct EventDetailLocationSection: View {
    let event: CalendarEvent

    @Environment(\.openURL) private var openURL

    /// Lugar resuelto del texto libre. nil → sin snippet de mapa.
    @State private var resolvedPlace: ResolvedPlace?
    @State private var didSearch = false

    var body: some View {
        if !event.isVirtual,
           let location = event.locationText,
           !location.isEmpty {
            Section {
                if let place = resolvedPlace {
                    Button {
                        openInMaps(location)
                    } label: {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: place.coordinate,
                            latitudinalMeters: 900,
                            longitudinalMeters: 900
                        ))) {
                            Marker(place.name ?? location, coordinate: place.coordinate)
                        }
                        .mapControlVisibility(.hidden)
                        .allowsHitTesting(false)
                        .frame(height: 160)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel("Abrir \(location) en Mapas")
                }
                Button {
                    openInMaps(location)
                } label: {
                    Label {
                        HStack {
                            Text(location)
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
                .task { await resolvePlaceIfNeeded(location) }
            } header: {
                Text("Ubicación")
            }
        }
    }

    private func resolvePlaceIfNeeded(_ location: String) async {
        guard !didSearch else { return }
        didSearch = true
        resolvedPlace = await Self.searchPlace(location)
    }

    /// Coordenada + nombre resueltos — struct Sendable para cruzar de la
    /// búsqueda nonisolated al @MainActor de la vista sin pelear con
    /// strict concurrency (MKLocalSearch.Response no es Sendable).
    private struct ResolvedPlace: Equatable, Sendable {
        var name: String?
        var latitude: Double
        var longitude: Double
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private nonisolated static func searchPlace(_ query: String) async -> ResolvedPlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        // boundingRegion.center en lugar de placemark — API no deprecada en iOS 26.
        let center = response.boundingRegion.center
        return ResolvedPlace(name: item.name, latitude: center.latitude, longitude: center.longitude)
    }

    private func openInMaps(_ location: String) {
        var components = URLComponents(string: "https://maps.apple.com/")
        var items = [URLQueryItem(name: "q", value: location)]
        if let place = resolvedPlace {
            items.append(URLQueryItem(name: "ll", value: "\(place.latitude),\(place.longitude)"))
        }
        components?.queryItems = items
        if let url = components?.url {
            openURL(url)
        }
    }
}
