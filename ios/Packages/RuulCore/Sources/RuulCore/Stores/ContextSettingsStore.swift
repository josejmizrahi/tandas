import Foundation
import Observation

/// F.1A-2 — store del shell de configuración del contexto.
@MainActor
@Observable
public final class ContextSettingsStore {
    public private(set) var settings: ContextSettings?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewSettings: ContextSettings) {
        self.rpc = rpc
        self.settings = previewSettings
        self.phase = .loaded
    }

    public func load(contextId: UUID) async {
        if settings == nil { phase = .loading }
        do {
            settings = try await rpc.contextSettingsSummary(contextId: contextId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    public func can(_ action: String) -> Bool { settings?.can(action) ?? false }
}
