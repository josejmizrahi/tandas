//
//  MapSection.swift
//  ResourceKit
//
//  Mini map preview + address card. Tapping the map (or the "Abrir en
//  Mapas" button) opens the event location in Apple Maps; the "…" button
//  offers Google Maps / Waze / Copy.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit
import RuulUI

// MARK: Map

struct MapSection: View {
    let title: String
    let location: MapLocation
    let accent: Color

    @State private var cameraPosition: MapCameraPosition
    @State private var showingOptions = false
    @Environment(\.openURL) private var openURL

    init(title: String, location: MapLocation, accent: Color) {
        self.title = title
        self.location = location
        self.accent = accent
        self._cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            )
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            SectionHeader(title: title)

            VStack(alignment: .leading, spacing: 0) {
                Map(position: $cameraPosition, interactionModes: []) {
                    Marker(location.title ?? "Ubicación", coordinate: location.coordinate)
                        .tint(accent)
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: false))
                .frame(height: 140)
                .contentShape(Rectangle())
                .onTapGesture { openInAppleMaps() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(location.title ?? "Ubicación")
                .accessibilityValue(location.address)
                .accessibilityHint("Toca para abrir en Mapas")
                .accessibilityAddTraits(.isButton)

                VStack(alignment: .leading, spacing: 10) {
                    if let t = location.title {
                        Text(t).font(.subheadline.weight(.semibold))
                    }
                    Text(location.address)
                        .font(.subheadline)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(3)

                    HStack(spacing: RuulSpacing.xs) {
                        Button(action: openInAppleMaps) {
                            Label("Abrir en Mapas", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .tint(accent)

                        Button { showingOptions = true } label: {
                            Image(systemName: "ellipsis")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 32, height: 32)
                        }
                        // Default accent — passing ruulFillGlassStrong as tint
                        // colored the ellipsis with the fill wash and made it
                        // disappear into the glass background.
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, RuulSpacing.sm)
            }
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .confirmationDialog("Direcciones", isPresented: $showingOptions, titleVisibility: .hidden) {
                Button("Apple Maps")  { openInAppleMaps() }
                Button("Google Maps") { openInGoogleMaps() }
                Button("Waze")        { openInWaze() }
                Button("Copiar dirección") { UIPasteboard.general.string = location.address }
                Button("Cancelar", role: .cancel) {}
            }
        }
    }

    private func openInAppleMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        item.name = location.title ?? location.address
        item.openInMaps()
    }

    private func openInGoogleMaps() {
        let coord = location.coordinate
        let app = URL(string: "comgooglemaps://?q=\(coord.latitude),\(coord.longitude)")
        let web = URL(string: "https://maps.google.com/?q=\(coord.latitude),\(coord.longitude)")
        if let app, UIApplication.shared.canOpenURL(app) { openURL(app) }
        else if let web { openURL(web) }
    }

    private func openInWaze() {
        let coord = location.coordinate
        let app = URL(string: "waze://?ll=\(coord.latitude),\(coord.longitude)&navigate=yes")
        let web = URL(string: "https://www.waze.com/ul?ll=\(coord.latitude),\(coord.longitude)&navigate=yes")
        if let app, UIApplication.shared.canOpenURL(app) { openURL(app) }
        else if let web { openURL(web) }
    }
}
