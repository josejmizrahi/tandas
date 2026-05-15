import Foundation

/// Pure-logic helper over `CapabilityCatalog.v1` answering dependency
/// questions for the capability management UI.
public struct CapabilityDependencyResolver: Sendable {
    public init() {}

    /// Returns block ids currently enabled on the resource that declare
    /// `targetId` as one of their dependencies. Disabling `targetId`
    /// would break them.
    public func dependents(
        of targetId: String,
        in enabledIds: Set<String>
    ) -> [String] {
        enabledIds.compactMap { id -> String? in
            guard id != targetId else { return nil }
            guard let block = CapabilityCatalog.v1.byId[id] else { return nil }
            return block.dependencies.contains(targetId) ? id : nil
        }
        .sorted()
    }

    /// Returns block ids that `targetId` declares as dependencies but
    /// are not currently enabled. Enabling `targetId` requires these.
    public func missingDependencies(
        of targetId: String,
        in enabledIds: Set<String>
    ) -> [String] {
        guard let block = CapabilityCatalog.v1.byId[targetId] else { return [] }
        return block.dependencies
            .filter { !enabledIds.contains($0) }
            .sorted()
    }
}
