import Foundation

/// Universal capability block — one module of a resource's detail surface.
/// Every enabled capability turns into ONE of these (or none, when it has
/// nothing meaningful to render and isn't worth even an empty prompt).
///
/// The `layoutKind` decides which sub-renderer the view picks. Builders
/// fill the right fields per layout. The View NEVER branches on
/// `resource.resourceType` — only on `block.layoutKind`.
public struct CapabilityBlock: Sendable, Hashable, Identifiable {
    /// Stable id. Conventionally the capability id ("rotation", "rsvp",
    /// "ledger", "evidence"). Multiple blocks may share a capability if
    /// the same module produces distinct surfaces (rare).
    public let id: String

    /// Human label rendered as the block header. "Rotación", "Asistencia",
    /// "Saldo", "Evidencia". Founder voice — no jargon.
    public let title: String

    /// SF Symbol for the block header glyph.
    public let icon: String

    /// Picks the sub-renderer in `CapabilityBlockView`.
    public let layoutKind: BlockLayoutKind

    /// Layout-specific payload. All layouts read from the same struct —
    /// each layout uses the subset relevant to it. Builders fill what
    /// their layout needs and leave the rest at default.
    public let payload: Payload

    /// Optional verb shown at the block footer ("Editar rotación",
    /// "Ver libro"). nil → no footer. When the user taps the block
    /// header chevron it opens whatever `onOpen` resolves to in the
    /// host's wiring.
    public let footerVerb: String?

    /// Opaque destination id the view passes back to the host on tap.
    /// The host (EventDetailHost / FundDetailHost / FineDetailCoordinator)
    /// owns the routing — the view just emits the id.
    public let openDestinationId: String?

    /// True when this block represents an obligation pending for the
    /// current viewer (RSVP not given, fine not paid, vote not cast).
    /// `BlockPriorityResolver` pulls these blocks to position 3 so the
    /// State Hero can call them out.
    public let isViewerObligation: Bool

    public init(
        id: String,
        title: String,
        icon: String,
        layoutKind: BlockLayoutKind,
        payload: Payload,
        footerVerb: String? = nil,
        openDestinationId: String? = nil,
        isViewerObligation: Bool = false
    ) {
        self.id = id; self.title = title; self.icon = icon
        self.layoutKind = layoutKind; self.payload = payload
        self.footerVerb = footerVerb; self.openDestinationId = openDestinationId
        self.isViewerObligation = isViewerObligation
    }

    /// Universal payload shape. Every layout reads from the same struct;
    /// builders populate only the fields their layout needs.
    public struct Payload: Sendable, Hashable {
        /// `summaryFacts` and any layout that wants extra key/value rows.
        public let facts: [FactRow]
        /// `avatarQueue`: ordered list of member ids.
        public let avatars: [AvatarRef]
        /// `mediaStrip`: thumbnail urls.
        public let media: [MediaRef]
        /// `balance`: pre-formatted currency string + signed delta.
        public let balance: BalanceFields?
        /// `progress`: numerator + denominator.
        public let progress: ProgressFields?
        /// `timelineMini`: 2-3 dated events.
        public let timeline: [TimelineEntry]
        /// `emptyPrompt`: one-line copy ("Vacío · Añade el primer movimiento").
        public let emptyPrompt: String?

        public init(
            facts: [FactRow] = [],
            avatars: [AvatarRef] = [],
            media: [MediaRef] = [],
            balance: BalanceFields? = nil,
            progress: ProgressFields? = nil,
            timeline: [TimelineEntry] = [],
            emptyPrompt: String? = nil
        ) {
            self.facts = facts; self.avatars = avatars; self.media = media
            self.balance = balance; self.progress = progress
            self.timeline = timeline; self.emptyPrompt = emptyPrompt
        }
    }

    public struct AvatarRef: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let initials: String
        public let badgeSymbol: String?  // "checkmark.circle.fill", "questionmark.circle"
        public init(id: UUID, initials: String, badgeSymbol: String? = nil) {
            self.id = id; self.initials = initials; self.badgeSymbol = badgeSymbol
        }
    }

    public struct MediaRef: Sendable, Hashable, Identifiable {
        public let id: String
        public let url: URL?
        public let placeholder: String   // SF Symbol when url missing
        public init(id: String, url: URL?, placeholder: String) {
            self.id = id; self.url = url; self.placeholder = placeholder
        }
    }

    public struct BalanceFields: Sendable, Hashable {
        public let primary: String       // "$4,300"
        public let supporting: String?   // "última aportación · 2 mar"
        public let delta: String?        // "+$200"
        public init(primary: String, supporting: String?, delta: String?) {
            self.primary = primary; self.supporting = supporting; self.delta = delta
        }
    }

    public struct ProgressFields: Sendable, Hashable {
        public let current: Int
        public let total: Int
        public let label: String         // "3 de 8 votos emitidos"
        public init(current: Int, total: Int, label: String) {
            self.current = current; self.total = total; self.label = label
        }
    }

    public struct TimelineEntry: Sendable, Hashable, Identifiable {
        public let id: String
        public let sentence: String      // "Apelación abierta por David"
        public let relativeTime: String  // "hace 2h"
        public init(id: String, sentence: String, relativeTime: String) {
            self.id = id; self.sentence = sentence; self.relativeTime = relativeTime
        }
    }
}
