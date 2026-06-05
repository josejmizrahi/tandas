import Foundation
import Observation

/// R.5A.F.3 — store del nuevo `context_detail_descriptor`. Mirror de
/// `ResourceDescriptorStore`. Co-existe con `ContextHomeStore` durante la
/// transición; F.3 ContextDetailView v2 lo consume.
@MainActor
@Observable
public final class ContextDescriptorStore {
    public private(set) var descriptor: ContextDetailDescriptor?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    public init(rpc: any RuulRPCClient, previewDescriptor: ContextDetailDescriptor) {
        self.rpc = rpc
        self.descriptor = previewDescriptor
        self.phase = .loaded
    }

    public func load(contextId: UUID) async {
        if descriptor == nil { phase = .loading }
        do {
            descriptor = try await rpc.contextDetailDescriptor(contextId: contextId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
}
