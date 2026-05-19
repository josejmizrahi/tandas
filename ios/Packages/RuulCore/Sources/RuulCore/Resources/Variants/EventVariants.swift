import Foundation

/// Beta-1 event variants. 3 ship; the rest live as comments below and
/// can be activated by appending one struct literal to `all`.
public enum EventVariants {
    public static let all: [ResourceVariant] = [
        socialGathering,
        recurringEvent,
        sportsMatch
    ]

    public static let socialGathering = ResourceVariant(
        id: "event.social_gathering",
        resourceType: .event,
        humanName: "Reunión social",
        summary: "Un momento coordinado con la gente.",
        examples: ["Cena", "Reunión", "Brindis", "Fiesta"],
        icon: "person.3.sequence",
        attachedCapabilities: [
            CapabilityID.schedule, CapabilityID.rules, CapabilityID.status, CapabilityID.history, CapabilityID.description, CapabilityID.hostActions
        ],
        suggestedIntents: [
            "invite_people",
            "check_in_attendees",
            "track_money",
            "link_resource",
            "add_rules",
            "view_history"
        ],
        postCreateHeadline: "Listo. ¿Qué quieres hacer ahora?"
    )

    public static let recurringEvent = ResourceVariant(
        id: "event.recurring_event",
        resourceType: .event,
        humanName: "Evento recurrente",
        summary: "Se repite cada semana, quincena o mes.",
        examples: ["Cena del jueves", "Junta semanal", "Entrenamiento"],
        icon: "calendar.badge.clock",
        // `recurrence` joins the silent set — it IS the variant. The
        // recurrence sub-config (frequency / day / time) is structural to
        // a recurring event; users still pick day+hour but the wizard
        // surfaces them inline as identity, not as a capability toggle.
        attachedCapabilities: [
            CapabilityID.schedule, CapabilityID.recurrence, CapabilityID.rules, CapabilityID.status, CapabilityID.history,
            CapabilityID.description, CapabilityID.hostActions
        ],
        suggestedIntents: [
            "invite_people",
            "check_in_attendees",
            "add_rules",
            "track_money",
            "link_resource",
            "view_history"
        ],
        postCreateHeadline: "Tu serie está activa. ¿Qué quieres hacer?"
    )

    /// V2 Slice 3A (Plans/Active/ProductCompression.md §D.2): hidden from
    /// the picker because it shares 5/6 intents with social_gathering and
    /// adds zero new silent capabilities. Stays registered for id-lookup
    /// on already-created resources; will resurface as a recipe chip
    /// inside the social_gathering identity form in a future pass.
    public static let sportsMatch = ResourceVariant(
        id: "event.sports_match",
        resourceType: .event,
        humanName: "Partido o competencia",
        summary: "Un encuentro con resultado o desempeño.",
        examples: ["Partido", "Carrera", "Torneo", "Match"],
        icon: "sportscourt",
        attachedCapabilities: [
            CapabilityID.schedule, CapabilityID.rules, CapabilityID.status, CapabilityID.history, CapabilityID.description, CapabilityID.hostActions
        ],
        suggestedIntents: [
            "link_resource",
            "invite_people",
            "check_in_attendees",
            "add_rules",
            "track_money",
            "view_history"
        ],
        postCreateHeadline: "¿Cómo organizamos este partido?",
        isVisibleInPicker: false
    )

    // post-Beta variants (uncomment + append to `all` when ready):
    //   - meeting        — "Junta de trabajo o decisión"
    //   - trip           — "Viaje compartido con itinerario"
    //   - ceremony       — "Boda, brit, graduación, ceremonia"
    //   - deadline       — "Algo que debe estar listo en una fecha"
}
