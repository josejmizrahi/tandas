import Foundation

/// Lookup interface for `ResourceVariant` records. Default impl backed
/// by a `[id: variant]` dictionary; alternate impls (mock, server-backed
/// later if we promote to `public.resource_variants`) can drop in.
public protocol ResourceVariantRegistry: Sendable {
    /// Variants for `type`, in display order. Empty when the type has no
    /// variants registered (placeholder types, future additions).
    func variants(for type: ResourceType) -> [ResourceVariant]

    /// Look up a variant by its stable id ("<type>.<name>").
    func variant(id: String) -> ResourceVariant?

    /// Every variant the registry knows about, in stable insertion order.
    /// Useful for tests / debug surfaces; production code should prefer
    /// `variants(for:)`.
    var allVariants: [ResourceVariant] { get }
}

/// In-memory registry backed by an insertion-ordered array + id index.
/// Construction asserts variant id uniqueness (precondition) so duplicate
/// catalog entries fail fast in DEBUG.
public struct DefaultResourceVariantRegistry: ResourceVariantRegistry {
    public let allVariants: [ResourceVariant]
    private let byId: [String: ResourceVariant]
    private let byType: [ResourceType: [ResourceVariant]]

    public init(_ variants: [ResourceVariant]) {
        precondition(
            Set(variants.map(\.id)).count == variants.count,
            "ResourceVariantRegistry: duplicate variant ids in catalog"
        )
        self.allVariants = variants
        self.byId = Dictionary(uniqueKeysWithValues: variants.map { ($0.id, $0) })
        self.byType = Dictionary(grouping: variants, by: \.resourceType)
    }

    public func variants(for type: ResourceType) -> [ResourceVariant] {
        byType[type] ?? []
    }

    public func variant(id: String) -> ResourceVariant? {
        byId[id]
    }

    /// Beta-1 catalog: 18 variants (3 per type). Hidden/post-Beta variants
    /// live as comments in each per-type file — adding one is a single
    /// struct-literal append, no enum or schema change.
    public static let v1: ResourceVariantRegistry = DefaultResourceVariantRegistry(
        EventVariants.all
        + FundVariants.all
        + AssetVariants.all
        + SpaceVariants.all
        + SlotVariants.all
        + RightVariants.all
    )
}
