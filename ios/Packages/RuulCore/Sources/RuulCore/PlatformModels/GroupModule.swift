import Foundation

/// A composable module a group can activate. Modules are the unit of
/// extension: V1 ships 5 (`basic_fines`, `rotating_host`, `rsvp`,
/// `check_in`, `appeal_voting`); Fase 2+ adds new modules (slot_assignment,
/// common_fund, contributions, etc.) by registering with `ModuleRegistry`.
///
/// A group's `activeModules` array (jsonb on `groups.active_modules`) lists
/// the module ids active in that group. Each module declares what it
/// provides + what it depends on so the registry can validate compatibility.
///
/// V1 modules are static structs in code (Bloque 5 — `ModuleRegistry`).
/// V2+ may load module manifests from the database for true plugin-style
/// extension, but V1's static path is intentionally simpler.
public struct GroupModule: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let providedRules: [String]                  // rule template names
    public let providedResourceTypes: [ResourceType]
    public let providedSystemEventTypes: [SystemEventType]
    public let providedTabs: [String]                   // tab ids if module adds chrome
    /// Capability block ids this module provides (mig 00078). Drives the
    /// expanded `CapabilityResolver` and the ResourceWizard surface.
    public let providedCapabilityBlocks: [String]
    public let dependencies: [String]                   // other module ids needed
    public let conflictsWith: [String]                  // mutually exclusive modules

    public init(
        id: String,
        name: String,
        description: String,
        providedRules: [String] = [],
        providedResourceTypes: [ResourceType] = [],
        providedSystemEventTypes: [SystemEventType] = [],
        providedTabs: [String] = [],
        providedCapabilityBlocks: [String] = [],
        dependencies: [String] = [],
        conflictsWith: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.providedRules = providedRules
        self.providedResourceTypes = providedResourceTypes
        self.providedSystemEventTypes = providedSystemEventTypes
        self.providedTabs = providedTabs
        self.providedCapabilityBlocks = providedCapabilityBlocks
        self.dependencies = dependencies
        self.conflictsWith = conflictsWith
    }
}
