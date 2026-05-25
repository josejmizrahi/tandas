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
    /// Live deadline used by the metric tile's countdown. nil → metric
    /// tile renders without countdown (resolved / appeal-style votes).
    public let closesAt: Date?
    /// True when the vote is still accepting ballots. Drives whether the
    /// metric tile renders at all (closed votes get the static rows path).
    public let isOpen: Bool
    public let inFavor: Int
    public let against: Int
    public let abstained: Int
    public let pending: Int
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
        closesAt: Date?,
        isOpen: Bool,
        inFavor: Int,
        against: Int,
        abstained: Int,
        pending: Int,
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
        self.closesAt = closesAt
        self.isOpen = isOpen
        self.inFavor = inFavor
        self.against = against
        self.abstained = abstained
        self.pending = pending
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

    /// Renders a Vote with a visual "Progreso" block (quorum ring +
    /// live countdown + animated tally bar with threshold tick) plus
    /// the decision rules section (quórum + mayoría). The cast picker
    /// opens via `onCast` from the inline action; admin finalize/cancel
    /// land in `toolbarMenu` and stay gated by the host.
    ///
    /// Closed votes drop the metric tile (countdown would be misleading)
    /// but keep the tally bar so the final split stays legible.
    ///
    /// `@MainActor` because the factory now embeds a SwiftUI view
    /// (`VoteProgressBlock`) into a `ResourceSection.custom(content:)`.
    /// Constructing an `AnyView` from a non-Sendable `VoteInput` requires
    /// isolation; every call site (`VoteDetailHost.makeConfig`) is already
    /// MainActor-bound so the annotation matches reality.
    @MainActor
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
            sections.append(.custom(
                id: "vote-progress",
                title: "Progreso",
                content: AnyView(VoteProgressBlock(input: vote))
            ))
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

// MARK: - VoteProgressBlock

/// Visual progress block embedded inside the universal resource detail
/// when rendering a vote. Composes:
///   - `VoteMetricsTile` (open votes only): micro quorum ring + live
///     countdown with urgent stroke under 6h to `closesAt`.
///   - `VoteCountsBar` with threshold tick: animated 6pt capsule
///     showing inFavor / against / pending split + the cutoff
///     in-favor needs to clear to pass.
///
/// Resolved / cancelled votes hide the tile (countdown is misleading)
/// and drop the threshold tick (the result is final). The bar still
/// renders so the final breakdown stays legible.
private struct VoteProgressBlock: View {
    let input: VoteInput

    private var castCount: Int { input.inFavor + input.against + input.abstained }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            if input.isOpen, let closesAt = input.closesAt {
                VoteMetricsTile(
                    closesAt: closesAt,
                    quorumPercent: input.quorumPercent,
                    totalEligible: input.totalEligible,
                    castCount: castCount
                )
            }
            VoteCountsBar(
                counts: VoteCounts(
                    inFavor: input.inFavor,
                    against: input.against,
                    abstained: input.abstained,
                    pending: input.pending,
                    totalEligible: input.totalEligible,
                    resolution: nil
                ),
                thresholdPercent: input.isOpen ? input.thresholdPercent : nil
            )
            .padding(RuulSpacing.md)
            .background(
                Color.ruulSurface,
                in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
            )
        }
    }
}
