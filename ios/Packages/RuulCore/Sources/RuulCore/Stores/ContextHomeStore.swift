import Foundation
import Observation

/// F.4 — store del Context Home. Una sola fuente: `context_summary()`.
/// Para el contexto personal agrega `my_world()` (recursos visibles con
/// razones + obligaciones cross-contexto).
@MainActor
@Observable
public final class ContextHomeStore {
    public private(set) var summary: ContextSummary?
    public private(set) var world: MyWorld?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview init.
    public init(rpc: any RuulRPCClient, previewSummary: ContextSummary, world: MyWorld? = nil) {
        self.rpc = rpc
        self.summary = previewSummary
        self.world = world
        self.phase = .loaded
    }

    public func load(context: AppContext) async {
        if summary == nil { phase = .loading }
        do {
            async let summaryTask = rpc.contextSummary(contextId: context.id)
            if context.isPersonal {
                async let worldTask = rpc.myWorld()
                let (loadedSummary, loadedWorld) = try await (summaryTask, worldTask)
                summary = loadedSummary
                world = loadedWorld
            } else {
                summary = try await summaryTask
                world = nil
            }
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
}
