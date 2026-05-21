//
//  ResourceConfig+Space.swift
//  ResourceKit
//
//  Sample `SpaceInput` model + `ResourceConfig.space(...)` factory.
//

import SwiftUI
import RuulCore
import RuulUI

// MARK: - SpaceInput

public struct SpaceInput {
    public let id: String
    public let name: String
    public let isActive: Bool
    public let capacity: Int
    public let location: String
    public let bookingsThisMonth: Int
    public let nextBookingTime: String?
    public let activity: [ActivityItem]

    public init(
        id: String,
        name: String,
        isActive: Bool,
        capacity: Int,
        location: String,
        bookingsThisMonth: Int,
        nextBookingTime: String?,
        activity: [ActivityItem]
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.capacity = capacity
        self.location = location
        self.bookingsThisMonth = bookingsThisMonth
        self.nextBookingTime = nextBookingTime
        self.activity = activity
    }
}

// MARK: - Factory

public extension ResourceConfig {

    // MARK: Espacio

    static func space(
        _ space: SpaceInput,
        onReserve: @escaping () -> Void = {},
        onSeeCalendar: @escaping () -> Void = {},
        onEdit: @escaping () -> Void = {}
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.assets.color
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "key.fill",
                name: space.name,
                typeLabel: "Espacio",
                badge: space.isActive ? ResourceBadge(text: "Activo", color: .ruulSemanticSuccess) : nil
            ),
            accent: accent,
            hero: HeroData(
                value: space.nextBookingTime ?? "Disponible",
                label: space.nextBookingTime == nil
                    ? "Sin reservas próximas"
                    : "Próxima reserva",
                size: .title
            ),
            actions: [
                ResourceAction(label: "Reservar", icon: "calendar.badge.plus", tint: accent, handler: onReserve),
                ResourceAction(label: "Calendario", handler: onSeeCalendar),
                ResourceAction(label: "Editar", handler: onEdit)
            ],
            sections: [
                .rows(title: "Detalles", items: [
                    RowItem(icon: "person.2", label: "Capacidad", value: .text("\(space.capacity) personas")),
                    RowItem(icon: "mappin", label: "Ubicación", value: .text(space.location)),
                    RowItem(icon: "star", label: "Reservas", value: .text("\(space.bookingsThisMonth) este mes"))
                ]),
                .empty(
                    title: "Próximas reservas",
                    icon: "calendar",
                    message: "Sin reservas próximas",
                    description: "Toca Reservar para apartar este espacio."
                )
            ],
            activity: .static(space.activity)
        )
    }
}
