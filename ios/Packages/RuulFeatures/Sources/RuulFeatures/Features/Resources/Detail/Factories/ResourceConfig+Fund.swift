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
        let movementsSection: ResourceSection = fund.movements.isEmpty
            ? .empty(
                title: "Movimientos",
                icon: "tray",
                message: "Sin movimientos aún",
                description: "Registra el primero para empezar a ver el historial."
            )
            : .rows(title: "Movimientos", items: fund.movements.prefix(5).map { item in
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
                label: "Saldo en MXN",
                size: .display,
                subRow: [
                    ("Aportado", fund.contributed.formatted(.currency(code: "MXN"))),
                    ("Retirado", fund.withdrawn.formatted(.currency(code: "MXN")))
                ]
            ),
            actions: [
                ResourceAction(label: "Aportar", icon: "arrow.down", tint: .ruulSemanticSuccess, handler: onContribute),
                ResourceAction(label: "Retirar", icon: "arrow.up", tint: .ruulSemanticError, handler: onWithdraw),
                ResourceAction(label: "Libro", handler: onSeeLedger)
            ],
            sections: [
                movementsSection,
                .avatars(
                    title: "Participantes",
                    people: fund.participants,
                    emptyText: nil,
                    onTapMore: onSeeParticipants
                )
            ],
            activity: activityLoader.map { .paginated($0) } ?? .static(fund.movements),
            toolbarMenu: [
                ToolbarMenuItem(label: "Exportar libro", icon: "square.and.arrow.up", handler: {}),
                ToolbarMenuItem(label: "Editar fondo", icon: "pencil", handler: {}),
                ToolbarMenuItem(label: "Cerrar fondo", icon: "lock", role: .destructive, handler: {})
            ]
        )
    }
}
