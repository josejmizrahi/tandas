import Foundation
import CoreLocation
import Observation

/// Wrapper de `CLLocationManager` para medir proximidad foreground al lugar de
/// un evento. Founder feedback 2026-06-20 "el checkin sea por ubicación".
///
/// Modo soft: solo activa cuando la vista lo pide (`requestUpdates`). No usa
/// background tracking ni geofences nativos (eso requiere
/// `NSLocationAlwaysAndWhenInUseUsageDescription` y aprobación heavier; aún
/// no firmada por founder).
///
/// El service tolera permisos denegados/restricted silenciosamente — la UI
/// caería al check-in manual de siempre. No es bloqueante.
@MainActor
@Observable
public final class LocationProximityService: NSObject {
    public enum Authorization: Sendable {
        case undetermined
        case denied
        case authorized
    }

    public private(set) var authorization: Authorization = .undetermined
    public private(set) var currentLocation: CLLocation?
    /// `true` cuando el manager está activo entregando updates. La UI lo usa
    /// para distinguir "esperando primera lectura" de "permiso denegado".
    public private(set) var isUpdating: Bool = false

    private let manager: CLLocationManager

    public override init() {
        self.manager = CLLocationManager()
        super.init()
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // 50m: balance entre precisión y batería. El check-in dispara a 200m,
        // así que 50m de delta es suficiente para detectar entrada/salida.
        self.manager.distanceFilter = 50
        self.authorization = mapAuthorization(self.manager.authorizationStatus)
    }

    /// Pide permiso si aún no se ha decidido y arranca updates. Idempotente.
    public func requestUpdates() {
        switch authorization {
        case .undetermined:
            manager.requestWhenInUseAuthorization()
            // Tras callback `locationManagerDidChangeAuthorization` arrancamos.
        case .authorized:
            if !isUpdating {
                manager.startUpdatingLocation()
                isUpdating = true
            }
        case .denied:
            break // No insistir; la UI sabe que el CTA enriquecido no aplica.
        }
    }

    public func stopUpdates() {
        if isUpdating {
            manager.stopUpdatingLocation()
            isUpdating = false
        }
    }

    /// Distancia a un target en metros. nil si aún no tenemos ubicación.
    public func distance(to lat: Double, lng: Double) -> CLLocationDistance? {
        guard let current = currentLocation else { return nil }
        let target = CLLocation(latitude: lat, longitude: lng)
        return current.distance(from: target)
    }

    private func mapAuthorization(_ status: CLAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .undetermined
        case .restricted, .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .undetermined
        }
    }
}

extension LocationProximityService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let mapped: Authorization = {
            switch manager.authorizationStatus {
            case .notDetermined: return .undetermined
            case .restricted, .denied: return .denied
            case .authorizedAlways, .authorizedWhenInUse: return .authorized
            @unknown default: return .undetermined
            }
        }()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorization = mapped
            if mapped == .authorized, !self.isUpdating {
                self.manager.startUpdatingLocation()
                self.isUpdating = true
            } else if mapped == .denied {
                self.stopUpdates()
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.currentLocation = latest
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent — la UI muestra el CTA manual de siempre cuando no hay reading.
    }
}
