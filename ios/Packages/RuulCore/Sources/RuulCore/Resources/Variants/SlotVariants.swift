import Foundation

/// Beta-1 slot variants. `assignment` and `booking` caps are
/// `.incomplete`; their intents (`assign_holder`, `allow_reservations`)
/// stay hidden until those caps promote.
public enum SlotVariants {
    public static let all: [ResourceVariant] = [
        seat,
        shift,
        ticket
    ]

    public static let seat = ResourceVariant(
        id: "slot.seat",
        resourceType: .slot,
        humanName: "Asiento",
        summary: "Un lugar puntual dentro de un espacio.",
        examples: ["Asiento del palco", "Silla numerada", "Butaca"],
        icon: "chair.lounge",
        attachedCapabilities: [
            CapabilityID.schedule, CapabilityID.rules, CapabilityID.status, CapabilityID.history, CapabilityID.description
        ],
        suggestedIntents: [
            "assign_holder",
            "allow_reservations",
            "define_priority",
            "add_rules",
            "link_resource",
            "view_history"
        ],
        postCreateHeadline: "¿De quién es este asiento?"
    )

    public static let shift = ResourceVariant(
        id: "slot.shift",
        resourceType: .slot,
        humanName: "Turno",
        summary: "Una ventana de tiempo asignable.",
        examples: ["Turno de guardia", "Slot horario", "Bloque de uso"],
        icon: "clock.arrow.2.circlepath",
        attachedCapabilities: [
            CapabilityID.schedule, CapabilityID.rules, CapabilityID.status, CapabilityID.history, CapabilityID.description
        ],
        suggestedIntents: [
            "assign_holder",
            "allow_reservations",
            "define_priority",
            "add_rules",
            "link_resource",
            "view_history"
        ],
        postCreateHeadline: "¿A quién le toca este turno?"
    )

    public static let ticket = ResourceVariant(
        id: "slot.ticket",
        resourceType: .slot,
        humanName: "Boleto",
        summary: "Una entrada para un evento o lugar.",
        examples: ["Boleto del partido", "Pase de entrada", "Acceso al evento"],
        icon: "ticket",
        attachedCapabilities: [
            CapabilityID.schedule, CapabilityID.rules, CapabilityID.status, CapabilityID.history, CapabilityID.description
        ],
        suggestedIntents: [
            "assign_holder",
            "link_resource",
            "add_rules",
            "view_history"
        ],
        postCreateHeadline: "¿Quién usa este boleto?"
    )

    // post-Beta variants:
    //   - time_block      — "Bloque genérico de tiempo"
    //   - parking_spot    — "Cajón de estacionamiento"
    //   - table           — "Mesa para X personas"
    //   - allocation_unit — "Unidad asignable abstracta"
}
