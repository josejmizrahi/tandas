import Foundation

/// Lookup interface for `ResourceIntent` records. Same shape as
/// `ResourceVariantRegistry` — id-indexed dictionary with insertion-
/// ordered list and id uniqueness asserted in DEBUG.
public protocol ResourceIntentRegistry: Sendable {
    /// Look up an intent by id. Used by the dispatcher + variant
    /// resolution (variants reference intent ids).
    func intent(id: String) -> ResourceIntent?

    /// Intents compatible with a resource type. The post-create screen
    /// composes the displayed list as `variant.suggestedIntents` mapped
    /// through `intent(id:)` and then intersected with `resourceTypes`.
    func intents(for type: ResourceType) -> [ResourceIntent]

    /// All known intents in insertion order.
    var allIntents: [ResourceIntent] { get }
}

public extension ResourceIntentRegistry {
    /// Intents the toolbar `+` can show right now for this resource +
    /// viewer. Adds the runtime state gate (`ResourceIntentRuntimeGate`)
    /// on top of the static type filter — hides intents whose
    /// per-instance state rule says no (e.g. "lock fund" when already
    /// locked).
    ///
    /// Caller is expected to then split the result by
    /// `intent.isResourceSetting` into the + menu vs ⚙️ menu, and to
    /// section the + items by `intent.group`.
    func available(in ctx: ResourceIntentContext) -> [ResourceIntent] {
        intents(for: ctx.resource.resourceType)
            .filter { ResourceIntentRuntimeGate.isAvailable($0, in: ctx) }
    }
}

public struct DefaultResourceIntentRegistry: ResourceIntentRegistry {
    public let allIntents: [ResourceIntent]
    private let byId: [String: ResourceIntent]

    public init(_ intents: [ResourceIntent]) {
        precondition(
            Set(intents.map(\.id)).count == intents.count,
            "ResourceIntentRegistry: duplicate intent ids in catalog"
        )
        self.allIntents = intents
        self.byId = Dictionary(uniqueKeysWithValues: intents.map { ($0.id, $0) })
    }

    public func intent(id: String) -> ResourceIntent? {
        byId[id]
    }

    public func intents(for type: ResourceType) -> [ResourceIntent] {
        allIntents.filter { $0.resourceTypes.contains(type) }
    }

    /// Beta-1 catalog of universal verbs.
    public static let v1: ResourceIntentRegistry = DefaultResourceIntentRegistry(
        DefaultIntents.all
    )
}
