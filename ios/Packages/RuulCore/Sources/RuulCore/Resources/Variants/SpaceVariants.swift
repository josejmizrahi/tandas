import Foundation

/// Beta-1 space variants. `access` and `booking` capabilities are
/// `.incomplete` in v1 catalog, so the intents that need them
/// (`grant_access`, `allow_reservations`) get hidden automatically by
/// the post-create screen until those caps promote to `.stable`.
public enum SpaceVariants {
    public static let all: [ResourceVariant] = [
        privateSpace,
        reservableSpace,
        venue
    ]

    public static let privateSpace = ResourceVariant(
        id: "space.private_space",
        resourceType: .space,
        humanName: "Espacio privado",
        summary: "Un lugar nuestro dentro de un recinto.",
        examples: ["Palco", "Suite", "Cuarto", "Box"],
        icon: "lock.square",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description, CapabilityID.maintenance
        ],
        suggestedIntents: [
            "grant_access",
            "create_child_event",
            "track_money",
            "add_rules",
            "link_resource",
            "view_history"
        ],
        postCreateHeadline: "Tu espacio existe. ¿Qué pasa adentro?"
    )

    public static let reservableSpace = ResourceVariant(
        id: "space.reservable_space",
        resourceType: .space,
        humanName: "Espacio reservable",
        summary: "Un lugar que se puede apartar por turnos.",
        examples: ["Cancha", "Salón", "Sala de juntas", "Estudio"],
        icon: "calendar.badge.checkmark",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description, CapabilityID.maintenance
        ],
        suggestedIntents: [
            "allow_reservations",
            "grant_access",
            "create_child_event",
            "track_money",
            "add_rules",
            "view_history"
        ],
        postCreateHeadline: "¿Cómo se aparta este lugar?"
    )

    /// V2 Slice 3A: hidden from the picker — venue = reservable_space +
    /// create_child_event, both of which already work on reservable_space
    /// directly. Stays registered for id-lookup; future pass surfaces it
    /// as a recipe chip inside reservable_space.
    public static let venue = ResourceVariant(
        id: "space.venue",
        resourceType: .space,
        humanName: "Recinto",
        summary: "Un lugar grande donde pasan muchas cosas.",
        examples: ["Estadio", "Foro", "Salón de eventos", "Casa"],
        icon: "building.columns",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description, CapabilityID.maintenance
        ],
        suggestedIntents: [
            "create_child_event",
            "allow_reservations",
            "grant_access",
            "track_money",
            "add_rules",
            "view_history"
        ],
        postCreateHeadline: "¿Qué quieres organizar aquí?",
        isVisibleInPicker: false
    )

    // post-Beta variants:
    //   - operational_space — "Lugar operativo (planta, oficina, bodega)"
    //   - parking           — "Estacionamiento o cajón"
    //   - room_seat_area    — "Área dentro de un recinto (mesa, fila)"
    //   - shared_space      — "Lugar compartido sin reservas"
}
