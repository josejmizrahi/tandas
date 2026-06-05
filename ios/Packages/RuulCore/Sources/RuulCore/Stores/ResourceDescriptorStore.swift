import Foundation
import Observation

/// R.5A.F.1 — store del nuevo `resource_detail_descriptor`. Una sola fuente:
/// `rpc.resourceDetailDescriptor(resourceId)`. Reemplaza eventualmente a
/// `ResourceDetailStore` cuando ResourceDetailView v2 alcance paridad con v1.
///
/// Co-existe con `ResourceDetailStore` durante la transición.
@MainActor
@Observable
public final class ResourceDescriptorStore {
    public private(set) var descriptor: ResourceDetailDescriptor?
    public private(set) var phase: StorePhase = .idle

    private let rpc: any RuulRPCClient

    public init(rpc: any RuulRPCClient) {
        self.rpc = rpc
    }

    /// Preview init.
    public init(rpc: any RuulRPCClient, previewDescriptor: ResourceDetailDescriptor) {
        self.rpc = rpc
        self.descriptor = previewDescriptor
        self.phase = .loaded
    }

    public func load(resourceId: UUID) async {
        if descriptor == nil { phase = .loading }
        do {
            descriptor = try await rpc.resourceDetailDescriptor(resourceId: resourceId)
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    /// Refresh barato post-execute (sólo actions, no todo el descriptor).
    public func refreshActions(resourceId: UUID) async {
        guard let current = descriptor else { return }
        do {
            let fresh = try await rpc.listResourceActions(resourceId: resourceId)
            descriptor = ResourceDetailDescriptor(
                resource: current.resource,
                class: current.class,
                subtype: current.subtype,
                effectiveCapabilities: current.effectiveCapabilities,
                rights: current.rights,
                sections: current.sections,
                widgets: current.widgets,
                actions: fresh,
                actionForms: current.actionForms,
                state: current.state,
                metrics: current.metrics,
                relations: current.relations,
                linkedEvents: current.linkedEvents,
                linkedDocuments: current.linkedDocuments,
                linkedObligations: current.linkedObligations,
                linkedDecisions: current.linkedDecisions,
                activityPreview: current.activityPreview
            )
        } catch {
            // No degradar el descriptor existente si el refresh falla
        }
    }
}
