import Foundation
import Supabase

/// Loads the module catalog from `public.modules` (mig 00060) via the
/// `list_modules()` RPC. Returns an immutable `ModuleRegistry` snapshot
/// the caller installs into `AppState.moduleRegistry`.
///
/// Decoding goes through a snake_case DTO because the server columns
/// don't match the Swift property names 1:1; the DTO maps strings into
/// the typed `SystemEventType` / `ResourceType` enums via their
/// `rawValue` Codable conformance, falling back to silent drop on
/// unknown raw values (forward-compat with iOS that hasn't pulled the
/// codegen for a freshly seeded module yet).
public actor LiveModuleRegistry {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func load() async throws -> ModuleRegistry {
        let rows: [ModuleRow] = try await client
            .rpc("list_modules")
            .execute()
            .value
        return ModuleRegistry(modules: rows.map { $0.toGroupModule() })
    }
}

/// Snake-case mirror of the `public.modules` row. Stays internal to
/// the loader — callers see `GroupModule` only.
private struct ModuleRow: Decodable, Sendable {
    let id: String
    let name: String
    let description: String?
    let provided_rules: [String]
    let provided_resource_types: [String]
    let provided_system_event_types: [String]
    let provided_tabs: [String]
    /// New in mig 00078. Optional decode for forward-compat with deployments
    /// that haven't applied 00078 yet (would return null/missing).
    let provided_capability_blocks: [String]?
    let dependencies: [String]
    let conflicts_with: [String]

    func toGroupModule() -> GroupModule {
        GroupModule(
            id: id,
            name: name,
            description: description ?? "",
            providedRules: provided_rules,
            providedResourceTypes: provided_resource_types.compactMap(decodeJSONString),
            providedSystemEventTypes: provided_system_event_types.compactMap(decodeJSONString),
            providedTabs: provided_tabs,
            providedCapabilityBlocks: provided_capability_blocks ?? [],
            dependencies: dependencies,
            conflictsWith: conflicts_with
        )
    }
}

/// `@codegen:enum` types (`SystemEventType`, `ResourceType`, etc.) are
/// Codable from a JSON string, but they don't expose a public
/// `init(rawValue:)`. Bridge a raw string through `JSONDecoder` so the
/// codegen-controlled init runs and unknown values fall through (or
/// fail silently for compactMap to drop).
private func decodeJSONString<T: Decodable>(_ raw: String) -> T? {
    let escaped = raw.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let json = "\"\(escaped)\""
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
