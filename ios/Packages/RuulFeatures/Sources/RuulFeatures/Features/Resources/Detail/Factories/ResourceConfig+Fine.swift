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
    /// Doctrine v2 §3 (PresenceBlock): fines used to show only the
    /// issuer as a text row. Now we render the fined person + (when
    /// different) the issuer as PresenceBlock-style avatar rows so
    /// the surface stops feeling like a citation notice.
    public let finedPerson: Person?
    public let issuerPerson: Person?
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
        finedPerson: Person? = nil,
        issuerPerson: Person? = nil,
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
        self.finedPerson = finedPerson
        self.issuerPerson = issuerPerson
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
        isPaying: Bool = false,
        onPay: @escaping () -> Void = {},
        onAppeal: @escaping () -> Void = {},
        toolbarMenu: [ToolbarMenuItem] = []
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.fines.color
        var actions: [ResourceAction] = []
        if fine.canPay {
            actions.append(ResourceAction(
                label: "Pagar",
                icon: "creditcard",
                tint: .ruulSemanticSuccess,
                isPending: isPaying,
                pendingLabel: "Pagando…",
                handler: onPay
            ))
        }
        if fine.canAppeal {
            actions.append(ResourceAction(label: "Apelar", icon: "exclamationmark.bubble", handler: onAppeal))
        }
        var sections: [ResourceSection] = []
        if let fined = fine.finedPerson {
            sections.append(.avatars(
                title: "A quién",
                people: [fined],
                emptyText: nil,
                onTapMore: nil
            ))
        }
        if let issuer = fine.issuerPerson, issuer.id != fine.finedPerson?.id {
            sections.append(.avatars(
                title: "Quién la puso",
                people: [issuer],
                emptyText: nil,
                onTapMore: nil
            ))
        }
        sections.append(.rows(title: "Detalles", items: [
            RowItem(icon: "doc.text", label: "Razón",   value: .text(fine.reason)),
            RowItem(icon: "calendar", label: "Emitida", value: .text(fine.createdAtLabel))
        ]))
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
