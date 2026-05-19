import Foundation

/// Human variant of a `ResourceType`. The user sees these in Step 2 of
/// the new Resource Creation flow (Type → Variant → Identity → Create →
/// Intents). Each variant is a curated UX recipe: it picks a subset of
/// builder fields for Step 3, declares which capabilities should attach
/// silently at create time, and orders the post-create intents the user
/// sees first.
///
/// Per founder doctrine (2026-05-18):
///   - Variants are universal, not vertical. "private_space" yes,
///     "palco_mundial" no.
///   - Hidden / post-Beta variants live as comments in each per-type
///     catalog file. The struct has no `.preview` status — a variant
///     either ships in v1 or it doesn't.
///   - Silent-attach rule: a capability is auto-attached only when it
///     is structural to the variant and requires zero user decision
///     (no threshold, no window, no who/when/how policy). Anything
///     needing config moves to an intent on the post-create screen.
public struct ResourceVariant: Sendable, Hashable, Identifiable {
    /// Stable client-side id. Convention: "<type>.<snake_case_name>"
    /// e.g. "event.recurring_event", "space.private_space". Not stored
    /// on the server today — variant choice flows through capability +
    /// rule attachments which the backend already knows about.
    public let id: String

    public let resourceType: ResourceType

    /// Short noun phrase shown on the variant card. Founder voice
    /// (colloquial Mexican Spanish). Never references doctrine terms
    /// (capability / atom / projection / trigger / consequence / ledger).
    public let humanName: String

    /// One-line description shown under `humanName` on the card.
    public let summary: String

    /// Concrete examples founders would recognize. Used for the
    /// "Ejemplos:" line on the variant card to anchor the abstract
    /// variant to real things ("palco", "nave", "coche").
    public let examples: [String]

    /// SF Symbol id. Resource type card has its own symbol; variant
    /// cards layer the variant's symbol so the user has two visual cues
    /// (type + variant).
    public let icon: String

    /// Identity fields surfaced in Step 3. Subset of the corresponding
    /// `ResourceBuilder.requiredFields`. A variant may also omit an
    /// otherwise-required field when the variant fills it deterministically
    /// (e.g. parent resource pre-filled by deeplink).
    public let identityFields: [BuilderField]

    /// Capability ids the activator attaches at create time WITHOUT
    /// asking the user. Filtered at runtime against:
    ///   1. the catalog (id must resolve to a `CapabilityBlock`)
    ///   2. the block's `status.isStable` gate
    ///   3. the resolver's `availableCapabilities(for:in:catalog:)`
    ///      for the group (active modules must provide it).
    /// Anything missing is silently skipped — no error surface.
    public let attachedCapabilities: Set<String>

    /// Ordered intent ids shown on the post-create screen. Each id must
    /// resolve in `ResourceIntentRegistry`. An intent whose required
    /// capabilities aren't `.stable` for the group is hidden by the
    /// screen, not greyed.
    public let suggestedIntents: [String]

    /// First-run copy shown above the post-create intent grid (one line,
    /// no jargon). Sets the tone — "Tu palco existe. ¿Qué quieres hacer
    /// ahora?" beats "Resource created successfully."
    public let postCreateHeadline: String

    /// Whether the variant picker shows this variant as a top-level card.
    /// Variants whose only differentiator is `humanName` (recipes) set
    /// this to `false` so the picker stays calm; they still resolve
    /// through `variant(id:)` for already-created resources, and a future
    /// pass can surface them as recipe chips inside the parent variant's
    /// identity form (V2 plan §D.3).
    ///
    /// Per V2 Product Compression doctrine (Plans/Active/ProductCompression.md
    /// §D.2), hiding a variant from the picker is the freeze-compatible
    /// way to compress the cognitive load — the catalog stays full, only
    /// visibility narrows.
    public let isVisibleInPicker: Bool

    public init(
        id: String,
        resourceType: ResourceType,
        humanName: String,
        summary: String,
        examples: [String] = [],
        icon: String,
        identityFields: [BuilderField] = [],
        attachedCapabilities: Set<String> = [],
        suggestedIntents: [String] = [],
        postCreateHeadline: String,
        isVisibleInPicker: Bool = true
    ) {
        self.id = id
        self.resourceType = resourceType
        self.humanName = humanName
        self.summary = summary
        self.examples = examples
        self.icon = icon
        self.identityFields = identityFields
        self.attachedCapabilities = attachedCapabilities
        self.suggestedIntents = suggestedIntents
        self.postCreateHeadline = postCreateHeadline
        self.isVisibleInPicker = isVisibleInPicker
    }
}
