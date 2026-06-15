import SwiftUI
import RuulCore

/// R.10.A — descriptor.sections drill-downs (code move, zero behavior change).
///
/// Doctrina: R.5V native-first · "Section is the card".
/// Movido del monolito previo (833–892).
///
/// 2026-06-08 founder feedback — antes había un Section con header literal
/// "Secciones" (meta naming anti-Apple) que listaba TODAS las secciones del
/// descriptor incluyendo las inertes con "Requiere: <capability>" expuesto
/// como texto técnico. Ahora:
///   - Solo se renderizan secciones routeable (filtra por sectionDestinationKey)
///   - Sin header — las rows quedan como NavigationLinks Apple-native
///   - Sin "Requiere: X" — el backend ya gate la sección via capabilities

struct ResourceDetailV2SectionsSection: View {
    let descriptor: ResourceDetailDescriptor
    let resourceId: UUID
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let routeable = descriptor.sections.filter { Self.destinationKey($0.sectionKey) != nil }
        if !routeable.isEmpty {
            Section {
                ForEach(routeable) { section in
                    NavigationLink {
                        destination(sectionKey: section.sectionKey)
                    } label: {
                        Label(section.displayName, systemImage: section.icon ?? "circle")
                    }
                }
            }
        }
    }

    static func destinationKey(_ key: String) -> String? {
        switch key {
        case "reservations", "availability", "calendar", "activity", "settings": return key
        default: return nil
        }
    }

    @ViewBuilder
    private func destination(sectionKey: String) -> some View {
        switch sectionKey {
        case "reservations":
            ReservationsListView(
                resource: descriptor.resource,
                context: context,
                reservationContextId: nil,
                container: container
            )
        case "availability", "calendar":
            // R.5V.Calendar 2026-06-09 — calendar standalone del recurso
            // (reservaciones + eventos linked vía sourceEventId).
            ResourceCalendarView(resource: descriptor.resource, context: context, container: container)
        case "activity":
            ActivityFeedView(context: context, container: container)
        case "settings":
            ResourceSettingsView(resourceId: resourceId, container: container)
        default:
            EmptyView()
        }
    }
}
