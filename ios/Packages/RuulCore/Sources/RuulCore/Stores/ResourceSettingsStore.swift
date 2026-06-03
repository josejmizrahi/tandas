import Foundation
import Observation

/// F.1A-3 — store del shell de configuración del recurso.
@MainActor
@Observable
public final class ResourceSettingsStore {
    public private(set) var settings: ResourceSettings?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewSettings: ResourceSettings) {
        self.rpc = rpc
        self.settings = previewSettings
        self.phase = .loaded
    }

    public func load(resourceId: UUID) async {
        if settings == nil { phase = .loading }
        do {
            settings = try await rpc.resourceSettingsSummary(resourceId: resourceId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func can(_ action: String) -> Bool { settings?.can(action) ?? false }
    public func has(_ capability: String) -> Bool { settings?.has(capability) ?? false }
}
