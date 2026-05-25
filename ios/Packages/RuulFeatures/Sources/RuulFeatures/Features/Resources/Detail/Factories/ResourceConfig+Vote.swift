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
    /// Doctrine v2 §3 (Presence): vote_casts RLS only exposes the
    /// viewer's own ballot — we can't list every voter client-side
    /// without backend changes. Surfacing the viewer's own cast (with
    /// avatar + choice + time) as a presence row is the honest
    /// minimum: at least one person becomes visible in a surface that
    /// was 100% aggregate counts. nil → section auto-hides.
    public let viewerVote: ViewerVote?
    public let activity: [ActivityItem]

    public struct ViewerVote {
        public let choice: VoteChoice
        public let castAt: Date?
        public let viewerName: String
        public let viewerAvatarURL: URL?

        public init(
            choice: VoteChoice,
            castAt: Date?,
            viewerName: String,
            viewerAvatarURL: URL?
        ) {
            self.choice = choice
            self.castAt = castAt
            self.viewerName = viewerName
            self.viewerAvatarURL = viewerAvatarURL
        }
    }

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
        viewerVote: ViewerVote? = nil,
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
        self.viewerVote = viewerVote
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
        if let viewerVote = vote.viewerVote, viewerVote.choice != .pending {
            sections.append(.custom(
                id: "viewer-vote",
                title: "Tu voto",
                content: AnyView(ViewerVoteRow(viewerVote: viewerVote))
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

// MARK: - ViewerVoteRow

/// Renders the viewer's own ballot as a presence row inside the vote
/// detail. Doctrine v2 §3 — at minimum the surface should make one
/// person visible (the viewer). Aggregate counts above remain the only
/// view of other voters' choices, per RLS.
@MainActor
private struct ViewerVoteRow: View {
    let viewerVote: VoteInput.ViewerVote

    var body: some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: viewerVote.viewerName,
                imageURL: viewerVote.viewerAvatarURL,
                size: .small
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewerVote.viewerName) · \(choicePhrase)")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                if let castAt = viewerVote.castAt {
                    Text(relativeTime(castAt))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Image(systemName: choiceIcon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(choiceTint)
        }
        .padding(RuulSpacing.md)
        .background(
            Color.ruulSurface,
            in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private var choicePhrase: String {
        switch viewerVote.choice {
        case .inFavor:   return "votaste a favor"
        case .against:   return "votaste en contra"
        case .abstained: return "te abstuviste"
        case .pending:   return ""
        }
    }

    private var choiceIcon: String {
        switch viewerVote.choice {
        case .inFavor:   return "checkmark.circle.fill"
        case .against:   return "xmark.circle.fill"
        case .abstained: return "minus.circle.fill"
        case .pending:   return "circle"
        }
    }

    private var choiceTint: Color {
        switch viewerVote.choice {
        case .inFavor:   return .ruulSemanticSuccess
        case .against:   return .ruulSemanticError
        case .abstained: return Color(.tertiaryLabel)
        case .pending:   return Color(.tertiaryLabel)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "es_MX")
        return f.localizedString(for: date, relativeTo: .now)
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
