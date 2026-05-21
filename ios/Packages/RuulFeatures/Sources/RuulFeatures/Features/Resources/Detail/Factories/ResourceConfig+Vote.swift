//
//  ResourceConfig+Vote.swift
//  ResourceKit
//
//  Sample `VoteInput` model + `ResourceConfig.vote(...)` factory.
//

import SwiftUI
import RuulCore
import RuulUI

// MARK: - VoteInput

public struct VoteInput {
    public let id: String
    public let title: String
    public let description: String?
    public let statusLabel: String        // "Abierta", "Resuelta · Aprobada", "Cancelada"
    public let voteTypeLabel: String       // "Apelación de multa", "Cambio de regla", etc.
    public let timingLabel: String         // "Cierra en 2 d", "Cerró hace 1 d"
    public let inFavor: Int
    public let against: Int
    public let abstained: Int
    public let totalEligible: Int
    public let quorumPercent: Int
    public let thresholdPercent: Int
    public let viewerAlreadyVoted: Bool
    public let activity: [ActivityItem]

    public init(
        id: String,
        title: String,
        description: String?,
        statusLabel: String,
        voteTypeLabel: String,
        timingLabel: String,
        inFavor: Int,
        against: Int,
        abstained: Int,
        totalEligible: Int,
        quorumPercent: Int,
        thresholdPercent: Int,
        viewerAlreadyVoted: Bool,
        activity: [ActivityItem]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.statusLabel = statusLabel
        self.voteTypeLabel = voteTypeLabel
        self.timingLabel = timingLabel
        self.inFavor = inFavor
        self.against = against
        self.abstained = abstained
        self.totalEligible = totalEligible
        self.quorumPercent = quorumPercent
        self.thresholdPercent = thresholdPercent
        self.viewerAlreadyVoted = viewerAlreadyVoted
        self.activity = activity
    }
}

// MARK: - Factory

public extension ResourceConfig {

    // MARK: Votación

    /// Renders a Vote with results breakdown (a-favor / en-contra /
    /// abstención / total elegibles) plus the decision rules section
    /// (quórum + mayoría). The cast picker opens via `onCast` from the
    /// inline action; admin finalize/cancel land in `toolbarMenu` and
    /// stay gated by the host.
    static func vote(
        _ vote: VoteInput,
        onCast: @escaping () -> Void = {},
        toolbarMenu: [ToolbarMenuItem] = []
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.votes.color
        let actions: [ResourceAction] = vote.viewerAlreadyVoted ? [] : [
            ResourceAction(label: "Emitir voto", icon: "checkmark.seal", tint: accent, handler: onCast)
        ]
        var sections: [ResourceSection] = []
        if vote.totalEligible > 0 {
            sections.append(.rows(title: "Resultados", items: [
                RowItem(icon: "hand.thumbsup",   label: "A favor",        value: .text("\(vote.inFavor)")),
                RowItem(icon: "hand.thumbsdown", label: "En contra",      value: .text("\(vote.against)")),
                RowItem(icon: "minus.circle",    label: "Abstención",     value: .text("\(vote.abstained)")),
                RowItem(icon: "person.3",        label: "Total elegibles",value: .text("\(vote.totalEligible)"))
            ]))
        }
        sections.append(.rows(title: "Reglas de decisión", items: [
            RowItem(icon: "checkmark.shield", label: "Quórum",            value: .text("\(vote.quorumPercent)%")),
            RowItem(icon: "scale.3d",         label: "Mayoría requerida", value: .text("\(vote.thresholdPercent)%"))
        ]))
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "checkmark.seal",
                name: vote.title,
                typeLabel: "Votación",
                metadata: [vote.voteTypeLabel],
                badge: nil
            ),
            accent: accent,
            hero: HeroData(
                value: vote.statusLabel,
                label: vote.timingLabel,
                size: .title
            ),
            actions: actions,
            sections: sections,
            activity: .static(vote.activity),
            toolbarMenu: toolbarMenu
        )
    }
}
