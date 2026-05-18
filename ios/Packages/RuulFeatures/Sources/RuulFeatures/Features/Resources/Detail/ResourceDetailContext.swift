import Foundation
import RuulCore

/// Everything a section renderer needs to draw itself. Built once by
/// the outer `ResourceDetailView` from the resource row + app state +
/// the loaded capability set, then passed down by value. Renderers
/// shouldn't mutate it — they should `@State` their own coordinators
/// for stateful work.
public struct ResourceDetailContext {
    /// Polymorphic resource row from `public.resources`.
    public let resource: ResourceRow

    /// Group the resource belongs to. Used for ledger / RSVP / rules
    /// queries that key on group_id.
    public let group: RuulCore.Group

    /// Acting user. May be nil during auth bootstrap; sections should
    /// degrade gracefully (read-only) when so.
    public let currentUserId: UUID?

    /// Set of capability ids the resource has enabled — read straight
    /// from `public.resource_capabilities` rows.
    public let enabledCapabilities: Set<String>

    /// Member directory for the group, keyed by `auth.users.id`. Sections
    /// that need to render avatars / display names lookup here.
    public let memberDirectory: [UUID: MemberWithProfile]

    /// Pre-resolved display name (falls back to type label when the
    /// resource metadata has no `name` / `title`). Avoids re-deriving
    /// it inside each section.
    public let displayName: String

    /// Optional inbox actions filtered to this resource (referenceId
    /// match). Empty when there's nothing pending.
    public let attentionActions: [UserAction]

    /// Callbacks the outer detail view hands down. Sections invoke
    /// these instead of pushing routes directly — keeps navigation
    /// state above the section layer.
    public let onPresentLedger: () -> Void
    public let onPresentRules: () -> Void
    public let onPresentEditResource: () -> Void
    public let onOpenInboxAction: (UserAction) async -> Void
    /// Tap callback for a member-row in any section (RSVP roll, attendance
    /// list, host check-in roll). Optional — when nil, sections render
    /// rows as display-only. EventDetailHost wires this to the attendee
    /// member detail sheet.
    public let onSelectMember: (UUID) -> Void
    /// Optional dismiss handler. Lets the outer shell tear down its own
    /// route binding (e.g. MainTabView's `detailRoute = nil`) before
    /// SwiftUI propagates `\.dismiss`. When nil, the top nav falls back
    /// to `\.dismiss` from the environment.
    public let onDismiss: (() -> Void)?

    /// Bubble for "the underlying `resources` row mutated" — sections
    /// that fire RPCs which write to `resources.metadata` (asset custody,
    /// asset ownership transfer, asset checkout, etc.) invoke this so
    /// the outer `ResourceDetailSheet` can re-fetch the row and rebuild
    /// the context. Without it the section's `asset.metadata` reads
    /// stay frozen to the value that was passed in at present-time.
    public let onResourceMutated: () async -> Void

    public init(
        resource: ResourceRow,
        group: RuulCore.Group,
        currentUserId: UUID?,
        enabledCapabilities: Set<String>,
        memberDirectory: [UUID: MemberWithProfile] = [:],
        displayName: String,
        attentionActions: [UserAction] = [],
        onPresentLedger: @escaping () -> Void = {},
        onPresentRules: @escaping () -> Void = {},
        onPresentEditResource: @escaping () -> Void = {},
        onOpenInboxAction: @escaping (UserAction) async -> Void = { _ in },
        onSelectMember: @escaping (UUID) -> Void = { _ in },
        onDismiss: (() -> Void)? = nil,
        onResourceMutated: @escaping () async -> Void = {}
    ) {
        self.resource = resource
        self.group = group
        self.currentUserId = currentUserId
        self.enabledCapabilities = enabledCapabilities
        self.memberDirectory = memberDirectory
        self.displayName = displayName
        self.attentionActions = attentionActions
        self.onPresentLedger = onPresentLedger
        self.onPresentRules = onPresentRules
        self.onPresentEditResource = onPresentEditResource
        self.onOpenInboxAction = onOpenInboxAction
        self.onSelectMember = onSelectMember
        self.onDismiss = onDismiss
        self.onResourceMutated = onResourceMutated
    }
}

