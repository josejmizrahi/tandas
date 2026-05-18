import Foundation
import RuulCore

/// One row in the INFORMACIÓN card. Type-erased to a (label, value) tuple
/// — the renderer (RuulInfoRow) doesn't need anything richer. Keep
/// strings already localized (callers format dates / amounts before
/// passing).
public struct ResourceInfoRow: Hashable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Per-type provider of "key facts" rows for the INFORMACIÓN card on
/// the resource detail page. Replaces the 120-line type switch that
/// previously lived in `UniversalResourceDetailView.typeSpecificRows`
/// per ontology constitution Rule 6 ("UI siempre capability-driven; cero
/// switch resource_type en routing"). Each type file registers its own
/// provider at boot — the universal view no longer needs to know which
/// metadata keys belong to which type.
@MainActor
public final class ResourceInfoRegistry {
    public static let shared = ResourceInfoRegistry()

    private var providers: [ResourceType: (ResourceDetailContext) -> [ResourceInfoRow]] = [:]

    private init() {
        // Wired here (instead of provider-side `register()` helpers) so the
        // call chain doesn't re-enter `shared` while `shared` is still in
        // its `dispatch_once` init — that re-entrancy traps with
        // EXC_BREAKPOINT in `_dispatch_once_wait`. Each provider stays the
        // owner of its `rows(for:)` logic; only the wiring lives here.
        register(type: .right, provider: RightInfoProvider.rows)
        register(type: .fund,  provider: FundInfoProvider.rows)
        register(type: .asset, provider: AssetInfoProvider.rows)
        register(type: .space, provider: SpaceInfoProvider.rows)
    }

    public func register(
        type: ResourceType,
        provider: @escaping (ResourceDetailContext) -> [ResourceInfoRow]
    ) {
        providers[type] = provider
    }

    /// Returns the rows for the resource's type, or an empty array when
    /// no provider is registered. Caller stitches the result into the
    /// universal INFORMACIÓN card between the generic date/host rows
    /// (above) and the universal "Creado" tail (below).
    public func rows(for context: ResourceDetailContext) -> [ResourceInfoRow] {
        providers[context.resource.resourceType]?(context) ?? []
    }
}
