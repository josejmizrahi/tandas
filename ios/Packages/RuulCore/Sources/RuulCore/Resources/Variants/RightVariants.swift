import Foundation

/// Beta-1 right variants. The right's holder + target are captured in
/// identity-step via the builder's `holderMemberId` + `targetResourceId`
/// fields, so no `assign_holder` capability is needed silently.
/// `access` cap is `.incomplete` — the `grant_access` intent stays
/// hidden for `access_right` until it promotes.
public enum RightVariants {
    public static let all: [ResourceVariant] = [
        accessRight,
        ownershipEquityRight,
        votingRight
    ]

    public static let accessRight = ResourceVariant(
        id: "right.access_right",
        resourceType: .right,
        humanName: "Derecho de acceso",
        summary: "Permiso de entrar o usar algo.",
        examples: ["Acceso al palco", "Membresía", "Permiso de uso"],
        icon: "key",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description
        ],
        suggestedIntents: [
            "assign_holder",
            "link_resource",
            "change_control",
            "add_rules",
            "view_history"
        ],
        postCreateHeadline: "¿A quién se le otorga este acceso?"
    )

    public static let ownershipEquityRight = ResourceVariant(
        id: "right.ownership_equity_right",
        resourceType: .right,
        humanName: "Participación",
        summary: "Una parte de algo: porcentaje, equity, copropiedad.",
        examples: ["50% del palco", "Equity de la nave", "Parte del coche"],
        icon: "chart.pie",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description,
            CapabilityID.valuation, CapabilityID.transfer, CapabilityID.delegation
        ],
        suggestedIntents: [
            "change_control",
            "define_priority",
            "link_resource",
            "view_history",
            "add_rules"
        ],
        postCreateHeadline: "La participación está registrada."
    )

    public static let votingRight = ResourceVariant(
        id: "right.voting_right",
        resourceType: .right,
        humanName: "Derecho a votar",
        summary: "Voz formal sobre decisiones del grupo.",
        examples: ["Voto del miembro", "Voto del consejo", "Voto del patrón"],
        icon: "checkmark.square",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description
        ],
        suggestedIntents: [
            "assign_holder",
            "link_resource",
            "change_control",
            "view_history"
        ],
        postCreateHeadline: "El derecho a votar quedó asignado."
    )

    // post-Beta variants:
    //   - usage_right      — "Derecho de uso (no propiedad)"
    //   - priority_right   — "Prioridad sobre algo"
    //   - membership_right — "Pertenencia formal a un círculo"
    //   - temporary_pass   — "Pase temporal con expiración"
    //   - delegation_right — "Derecho de delegar otra cosa"
}
