import Foundation

/// Beta-1 asset variants. Silent attaches are physical-asset capabilities
/// that have zero required config (custody/valuation/maintenance just
/// allow recording events; the user opts into the *content*).
public enum AssetVariants {
    public static let all: [ResourceVariant] = [
        property,
        vehicle,
        investmentHolding
    ]

    public static let property = ResourceVariant(
        id: "asset.property",
        resourceType: .asset,
        humanName: "Inmueble",
        summary: "Una propiedad con valor, custodia y gastos.",
        examples: ["Casa de campo", "Nave", "Bodega", "Terreno"],
        icon: "building.2",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description,
            CapabilityID.custody, CapabilityID.valuation, CapabilityID.location, CapabilityID.maintenance
        ],
        suggestedIntents: [
            "link_resource",
            "record_valuation",
            "assign_custody",
            "track_money",
            "add_rules",
            "view_history"
        ],
        postCreateHeadline: "Vincula el fondo o registra una valuación."
    )

    public static let vehicle = ResourceVariant(
        id: "asset.vehicle",
        resourceType: .asset,
        humanName: "Vehículo",
        summary: "Algo que se conduce, se presta y se mantiene.",
        examples: ["Coche", "Camioneta", "Lancha", "Bici"],
        icon: "car",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description,
            CapabilityID.custody, CapabilityID.valuation, CapabilityID.maintenance
        ],
        suggestedIntents: [
            "assign_custody",
            "record_valuation",
            "track_money",
            "add_rules",
            "link_resource",
            "view_history"
        ],
        postCreateHeadline: "¿Quién lo trae hoy?"
    )

    public static let investmentHolding = ResourceVariant(
        id: "asset.investment_holding",
        resourceType: .asset,
        humanName: "Inversión o participación",
        summary: "Algo que vale dinero y cambia de valor con el tiempo.",
        examples: ["Acciones", "Equity", "Instrumento financiero"],
        icon: "banknote",
        attachedCapabilities: [
            CapabilityID.status, CapabilityID.history, CapabilityID.description,
            CapabilityID.valuation
        ],
        suggestedIntents: [
            "record_valuation",
            "link_resource",
            "track_money",
            "add_rules",
            "view_history",
            "change_control"
        ],
        postCreateHeadline: "Registra el valor actual o vincula el fondo."
    )

    // post-Beta variants:
    //   - equipment      — "Equipo (cámara, herramientas, instrumentos)"
    //   - document_contract — "Contrato, escritura, póliza"
    //   - inventory      — "Stock de unidades contables"
    //   - digital_asset  — "Dominio, cuenta, IP"
    //   - ownership_stake — (use Right.ownership_equity_right instead)
}
