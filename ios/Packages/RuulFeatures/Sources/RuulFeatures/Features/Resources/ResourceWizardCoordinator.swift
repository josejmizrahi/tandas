import Foundation
import OSLog
import RuulCore

/// Drives the ResourceWizardSheet — the progressive opt-in creation flow
/// that surfaces Capability Foundation blocks as toggles.
///
/// V1 scope: event creation only (EventResourceBuilder is the only
/// implemented builder). Wizard renders required fields (title + date)
/// plus a collapsible "Opciones" panel with toggles for the V1 blocks
/// the group can enable (resolver-gated).
@Observable @MainActor
public final class ResourceWizardCoordinator {
    public var title: String = ""
    public var startsAt: Date
    public var enabledCapabilities: Set<String> = []

    public private(set) var isCreating: Bool = false
    public private(set) var error: String?
    public private(set) var createdResourceId: UUID?

    public let group: Group
    public let availableCapabilities: [any CapabilityBlock]

    private let builder: EventResourceBuilder
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.wizard")

    public init(
        group: Group,
        suggestedDate: Date,
        availableCapabilities: [any CapabilityBlock],
        builder: EventResourceBuilder,
        defaultEnabled: Set<String> = []
    ) {
        self.group = group
        self.startsAt = suggestedDate
        self.availableCapabilities = availableCapabilities
        self.builder = builder
        self.enabledCapabilities = defaultEnabled
    }

    public var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !isCreating
    }

    public var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func toggleCapability(_ blockId: String) {
        if enabledCapabilities.contains(blockId) {
            enabledCapabilities.remove(blockId)
            // When a block is turned off, also turn off any blocks that
            // depend on it (keep the set internally consistent so the
            // user can't ship a draft that the builder will reject).
            let catalog = CapabilityCatalog.v1
            for block in availableCapabilities where enabledCapabilities.contains(block.id) {
                if block.dependencies.contains(blockId) {
                    enabledCapabilities.remove(block.id)
                }
            }
            _ = catalog  // silence unused warning if catalog is removed later
        } else {
            enabledCapabilities.insert(blockId)
            // Pull in transitive dependencies so the user doesn't have to
            // manually opt in to prerequisites (e.g. enabling check_in
            // pulls in rsvp).
            if let block = availableCapabilities.first(where: { $0.id == blockId }) {
                for dep in block.dependencies {
                    enabledCapabilities.insert(dep)
                }
            }
        }
    }

    public func isEnabled(_ blockId: String) -> Bool {
        enabledCapabilities.contains(blockId)
    }

    public func submit() async -> Bool {
        guard canSubmit else { return false }
        isCreating = true
        error = nil
        defer { isCreating = false }

        let draft = ResourceDraft(
            groupId: group.id,
            resourceType: .event,
            basicFields: [
                "title":    .string(trimmedTitle),
                "startsAt": .string(ISO8601DateFormatter().string(from: startsAt))
            ],
            enabledCapabilities: Array(enabledCapabilities),
            capabilityConfigs: [:],
            seriesPattern: nil,
            initialRules: []
        )

        do {
            let result = try await builder.build(draft)
            createdResourceId = result.resourceId
            log.debug("created resource \(result.resourceId) with capabilities \(result.enabledCapabilityIds.joined(separator: ","))")
            return true
        } catch let e as ResourceBuilderError {
            self.error = userFacing(error: e)
            log.warning("wizard build failed: \(String(describing: e))")
            return false
        } catch {
            self.error = "No pudimos crear el recurso: \(error.localizedDescription)"
            log.warning("wizard build failed: \(error.localizedDescription)")
            return false
        }
    }

    private func userFacing(error: ResourceBuilderError) -> String {
        switch error {
        case .missingRequiredField(let key):
            return "Falta el campo: \(key)"
        case .unsupportedCapability(let id):
            return "Capacidad no soportada: \(id)"
        case .capabilityConflict(let a, let b):
            return "\(a) no se puede activar con \(b)"
        case .rpcFailed(let message):
            return "Error del servidor: \(message)"
        case .underlying(let message):
            return message
        }
    }
}
