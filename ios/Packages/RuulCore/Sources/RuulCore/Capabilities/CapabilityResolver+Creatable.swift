import Foundation

public extension CapabilityResolver {
    /// Resource types the current group is allowed to create.
    ///
    /// Pass 2: returns all 6 canonical platform types unconditionally.
    /// The UI layer (TypePicker) is responsible for gating individual
    /// tiles based on whether a `ResourceBuilder` is registered for each
    /// type — types without a builder appear as "Próximamente" placeholders.
    ///
    /// Pass 3 polish: filter here by `group.activeModules` / template /
    /// governance so groups with restricted charters only see the types
    /// their template declares.
    func creatableTypes(group: Group) -> [ResourceType] {
        [.event, .fund, .asset, .space, .slot, .right]
    }
}
