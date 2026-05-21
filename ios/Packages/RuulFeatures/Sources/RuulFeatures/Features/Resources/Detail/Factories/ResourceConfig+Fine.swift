//
//  ResourceConfig+Fine.swift
//  ResourceKit
//
//  Sample `FineInput` model + `ResourceConfig.fine(...)` factory.
//

import SwiftUI
import RuulCore
import RuulUI

// MARK: - FineInput

public struct FineInput {
    public let id: String
    public let reason: String
    public let amountFormatted: String
    public let statusLabel: String
    public let createdAtLabel: String
    public let issuedByName: String?
    public let canPay: Bool
    public let canAppeal: Bool
    public let appealStatusLabel: String?
    public let activity: [ActivityItem]

    public init(
        id: String,
        reason: String,
        amountFormatted: String,
        statusLabel: String,
        createdAtLabel: String,
        issuedByName: String?,
        canPay: Bool,
        canAppeal: Bool,
        appealStatusLabel: String?,
        activity: [ActivityItem]
    ) {
        self.id = id
        self.reason = reason
        self.amountFormatted = amountFormatted
        self.statusLabel = statusLabel
        self.createdAtLabel = createdAtLabel
        self.issuedByName = issuedByName
        self.canPay = canPay
        self.canAppeal = canAppeal
        self.appealStatusLabel = appealStatusLabel
        self.activity = activity
    }
}

// MARK: - Factory

public extension ResourceConfig {

    // MARK: Multa

    /// Renders a Fine with the amount as the dominant hero metric +
    /// status as label. Pay / Appeal lives inline as gated actions;
    /// admin "Anular" lands in `toolbarMenu`. Detail rows expose
    /// reason, emisor, and timing; an "Apelación" section only renders
    /// when `appealStatusLabel` is set.
    static func fine(
        _ fine: FineInput,
        onPay: @escaping () -> Void = {},
        onAppeal: @escaping () -> Void = {},
        toolbarMenu: [ToolbarMenuItem] = []
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.fines.color
        var actions: [ResourceAction] = []
        if fine.canPay {
            actions.append(ResourceAction(label: "Pagar", icon: "creditcard", tint: .ruulSemanticSuccess, handler: onPay))
        }
        if fine.canAppeal {
            actions.append(ResourceAction(label: "Apelar", icon: "exclamationmark.bubble", handler: onAppeal))
        }
        var detailRows: [RowItem] = [
            RowItem(icon: "doc.text", label: "Razón",   value: .text(fine.reason)),
            RowItem(icon: "calendar", label: "Emitida", value: .text(fine.createdAtLabel))
        ]
        if let issuer = fine.issuedByName {
            detailRows.append(RowItem(icon: "person", label: "Emisor", value: .text(issuer)))
        }
        var sections: [ResourceSection] = [
            .rows(title: "Detalles", items: detailRows)
        ]
        if let appealLabel = fine.appealStatusLabel {
            sections.append(.rows(title: "Apelación", items: [
                RowItem(icon: "exclamationmark.bubble", label: "Estado", value: .text(appealLabel))
            ]))
        }
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "exclamationmark.bubble",
                name: fine.reason,
                typeLabel: "Multa",
                metadata: [fine.statusLabel],
                badge: nil
            ),
            accent: accent,
            hero: HeroData(
                value: fine.amountFormatted,
                label: fine.statusLabel,
                size: .display
            ),
            actions: actions,
            sections: sections,
            activity: .static(fine.activity),
            toolbarMenu: toolbarMenu
        )
    }
}
