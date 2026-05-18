import Foundation

/// Beta-1 fund variants. Silent attaches: `ledger`+`money` are
/// foundational to what a fund IS; without them a fund is just a label.
public enum FundVariants {
    public static let all: [ResourceVariant] = [
        sharedExpenses,
        travelFund,
        investmentFund
    ]

    public static let sharedExpenses = ResourceVariant(
        id: "fund.shared_expenses",
        resourceType: .fund,
        humanName: "Gastos compartidos",
        summary: "Lo que pagamos entre todos y vamos saldando.",
        examples: ["Cuentas del depa", "Gastos de la casa", "Servicios"],
        icon: "creditcard.and.123",
        attachedCapabilities: [
            "ledger", "money", "rules", "status", "history", "description"
        ],
        suggestedIntents: [
            "record_expense",
            "record_contribution",
            "link_resource",
            "view_balance",
            "add_rules",
            "change_control"
        ],
        postCreateHeadline: "El fondo está abierto. ¿Qué quieres registrar?"
    )

    public static let travelFund = ResourceVariant(
        id: "fund.travel_fund",
        resourceType: .fund,
        humanName: "Fondo de viaje",
        summary: "Lo que ahorramos juntos para ir a algún lado.",
        examples: ["Viaje fin de año", "Mundial", "Boda en la playa"],
        icon: "airplane.departure",
        attachedCapabilities: [
            "ledger", "money", "rules", "status", "history", "description"
        ],
        suggestedIntents: [
            "record_contribution",
            "record_expense",
            "link_resource",
            "view_balance",
            "add_rules",
            "change_control"
        ],
        postCreateHeadline: "Listo para empezar a juntar."
    )

    public static let investmentFund = ResourceVariant(
        id: "fund.investment_fund",
        resourceType: .fund,
        humanName: "Fondo de inversión",
        summary: "Capital compartido con propósito patrimonial.",
        examples: ["Capital del negocio", "Pool de la nave", "Equity común"],
        icon: "chart.line.uptrend.xyaxis",
        attachedCapabilities: [
            "ledger", "money", "rules", "status", "history", "description"
        ],
        suggestedIntents: [
            "link_resource",
            "record_contribution",
            "record_expense",
            "add_rules",
            "view_balance",
            "change_control"
        ],
        postCreateHeadline: "Vincula el activo o registra el primer aporte."
    )

    // post-Beta variants:
    //   - maintenance_fund — "Para mantener algo (nave, palco, equipo)"
    //   - treasury         — "Tesorería operativa del grupo"
    //   - donation_fund    — "Bote para causa o donativo"
    //   - emergency_fund   — "Reserva para imprevistos"
}
