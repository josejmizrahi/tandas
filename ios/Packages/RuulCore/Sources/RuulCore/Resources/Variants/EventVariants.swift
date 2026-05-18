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
            "schedule", "rules", "status", "history", "description", "host_actions"
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
            "schedule", "recurrence", "rules", "status", "history",
            "description", "host_actions"
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

    public static let sportsMatch = ResourceVariant(
        id: "event.sports_match",
        resourceType: .event,
        humanName: "Partido o competencia",
        summary: "Un encuentro con resultado o desempeño.",
        examples: ["Partido", "Carrera", "Torneo", "Match"],
        icon: "sportscourt",
        attachedCapabilities: [
            "schedule", "rules", "status", "history", "description", "host_actions"
        ],
        suggestedIntents: [
            "link_resource",
            "invite_people",
            "check_in_attendees",
            "add_rules",
            "track_money",
            "view_history"
        ],
        postCreateHeadline: "¿Cómo organizamos este partido?"
    )

    // post-Beta variants (uncomment + append to `all` when ready):
    //   - meeting        — "Junta de trabajo o decisión"
    //   - trip           — "Viaje compartido con itinerario"
    //   - ceremony       — "Boda, brit, graduación, ceremonia"
    //   - deadline       — "Algo que debe estar listo en una fecha"
}
