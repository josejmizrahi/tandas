//
//  ResourceConfig+Fund.swift
//  ResourceKit
//
//  Sample `FundInput` model + `ResourceConfig.fund(...)` factory.
//

import SwiftUI
import RuulCore
import RuulUI

// MARK: - FundInput

public struct FundInput {
    public let id: String
    public let name: String
    public let createdAgo: String       // "hace 2 d"
    public let balance: Decimal
    public let contributed: Decimal
    public let withdrawn: Decimal
    public let participants: [Person]
    public let movements: [ActivityItem]

    public init(
        id: String,
        name: String,
        createdAgo: String,
        balance: Decimal,
        contributed: Decimal,
        withdrawn: Decimal,
        participants: [Person],
        movements: [ActivityItem]
    ) {
        self.id = id
        self.name = name
        self.createdAgo = createdAgo
        self.balance = balance
        self.contributed = contributed
        self.withdrawn = withdrawn
        self.participants = participants
        self.movements = movements
    }
}

// MARK: - Factory

public extension ResourceConfig {

    // MARK: Fondo

    static func fund(
        _ fund: FundInput,
        onContribute: @escaping () -> Void = {},
        onWithdraw: @escaping () -> Void = {},
        onSeeLedger: @escaping () -> Void = {},
        onSeeParticipants: @escaping () -> Void = {},
        activityLoader: ActivityLoader? = nil
    ) -> ResourceConfig {
        // Doctrine v2 §4 + §7: vocabulary purge. "Movimientos" /
        // "Saldo" / "Aportado" / "Retirado" / "Libro" all read as
        // accounting language. Replaced with people-talk equivalents
        // ("Lo último de dinero", "El grupo tiene", "Han aportado",
        // "Han sacado", "Ver todo").
        let movementsSection: ResourceSection = fund.movements.isEmpty
            ? .empty(
                title: "Lo último de dinero",
                icon: "tray",
                message: "Aún no ha pasado nada con este dinero",
                description: "Aporta o registra un gasto para empezar."
            )
            : .rows(title: "Lo último de dinero", items: fund.movements.prefix(5).map { item in
                RowItem(
                    icon: item.icon,
                    label: item.title,
                    value: .text(item.subtitle ?? "")
                )
            })

        let accent = ResourceFamilyTint.funds.color
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "banknote",
                name: fund.name,
                typeLabel: "Fondo",
                metadata: ["Creado \(fund.createdAgo)"]
            ),
            accent: accent,
            hero: HeroData(
                value: fund.balance.formatted(.currency(code: "MXN")),
                label: "El grupo tiene",
                size: .display,
                subRow: [
                    HeroPair("Han aportado", fund.contributed.formatted(.currency(code: "MXN"))),
                    HeroPair("Han sacado",   fund.withdrawn.formatted(.currency(code: "MXN")))
                ]
            ),
            actions: [
                ResourceAction(label: "Aportar", icon: "arrow.down", tint: .ruulSemanticSuccess, handler: onContribute),
                ResourceAction(label: "Sacar",   icon: "arrow.up",   tint: .ruulSemanticError,   handler: onWithdraw),
                ResourceAction(label: "Ver todo", handler: onSeeLedger)
            ],
            sections: [
                movementsSection,
                .avatars(
                    title: "Quienes participan",
                    people: fund.participants,
                    emptyText: nil,
                    onTapMore: onSeeParticipants
                )
            ],
            activity: activityLoader.map { .paginated($0) } ?? .static(fund.movements),
            toolbarMenu: [
                ToolbarMenuItem(label: "Exportar historia", icon: "square.and.arrow.up", handler: {}),
                ToolbarMenuItem(label: "Editar fondo",      icon: "pencil",              handler: {}),
                ToolbarMenuItem(label: "Cerrar este fondo", icon: "lock", role: .destructive, handler: {})
            ]
        )
    }
}
