import Foundation
import OSLog
import RuulCore

/// Universal ResourceWizard coordinator. Drives the multi-step flow:
///
///   1. typePicker — choose what to create (Event, Asset, Slot, …)
///   2. fields     — fill the builder's requiredFields
///   3. options    — toggle capability blocks (filtered by resource type)
///   4. submit     — route to the selected ResourceBuilder
///
/// Persists step state so back/forward navigation feels natural.
public enum ResourceWizardStep: Int, Sendable, CaseIterable {
    case typePicker
    case fields
    case options
}

@Observable @MainActor
public final class ResourceWizardCoordinator {
    public let group: Group
    public let registry: ResourceBuilderRegistry
    public let catalog: CapabilityCatalog

    public private(set) var step: ResourceWizardStep = .typePicker
    public private(set) var selectedBuilder: (any ResourceBuilder)?
    public var basicFields: [String: JSONConfig] = [:]
    public var enabledCapabilities: Set<String> = []

    public private(set) var isCreating: Bool = false
    public private(set) var error: String?
    public private(set) var createdResourceId: UUID?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.wizard")
    private let resolver: CapabilityResolver

    public init(
        group: Group,
        registry: ResourceBuilderRegistry,
        catalog: CapabilityCatalog = .v1,
        resolver: CapabilityResolver = CapabilityResolver()
    ) {
        self.group = group
        self.registry = registry
        self.catalog = catalog
        self.resolver = resolver
    }

    // MARK: - Step navigation

    public func selectBuilder(_ builder: any ResourceBuilder) {
        selectedBuilder = builder
        basicFields = [:]
        // Pre-fill defaults for non-text fields so validateRequiredFields
        // passes immediately. Without this, the date binding in
        // BuilderFieldRenderer only fires its `set` on user interaction —
        // so a user who just types a title (without tapping the date
        // picker) hits a silently-disabled CTA.
        let iso = ISO8601DateFormatter()
        let defaultDate = Date.now.addingTimeInterval(86_400)
        for field in builder.requiredFields {
            switch field.kind {
            case .date, .time, .dateTime, .duration:
                basicFields[field.key] = .string(iso.string(from: defaultDate))
            case .boolean:
                basicFields[field.key] = .bool(false)
            case .integer, .decimal, .currency, .money:
                basicFields[field.key] = .int(0)
            default:
                break  // text/picker/resource — wait for user input
            }
        }
        enabledCapabilities = defaultCapabilitiesFor(builder)
        step = .fields
    }

    public func goBack() {
        switch step {
        case .typePicker: return
        case .fields:     step = .typePicker; selectedBuilder = nil
        case .options:    step = .fields
        }
    }

    public func advanceFromFields() {
        guard validateRequiredFields() else { return }
        step = .options
    }

    public var canAdvanceFromFields: Bool {
        validateRequiredFields()
    }

    /// Capability blocks the picker should show in step 3 — filtered by:
    /// (1) the selected builder declares them, AND
    /// (2) the resolver says they're available on this group.
    public var availableCapabilityBlocks: [any CapabilityBlock] {
        guard let builder = selectedBuilder else { return [] }
        let groupAvailable = Set(resolver.availableCapabilities(
            for: builder.resourceType, in: group, catalog: catalog
        ))
        return builder.optionalCapabilities
            .filter { groupAvailable.contains($0) }
            .compactMap { catalog[$0] }
    }

    public func toggleCapability(_ blockId: String) {
        if enabledCapabilities.contains(blockId) {
            enabledCapabilities.remove(blockId)
            // Drop dependents whose deps just disappeared.
            for block in availableCapabilityBlocks where enabledCapabilities.contains(block.id) {
                if block.dependencies.contains(blockId) {
                    enabledCapabilities.remove(block.id)
                }
            }
        } else {
            enabledCapabilities.insert(blockId)
            // Pull in transitive deps.
            if let block = availableCapabilityBlocks.first(where: { $0.id == blockId }) {
                for dep in block.dependencies {
                    enabledCapabilities.insert(dep)
                }
            }
        }
    }

    public func isCapabilityEnabled(_ blockId: String) -> Bool {
        enabledCapabilities.contains(blockId)
    }

    // MARK: - Submit

    public var canSubmit: Bool {
        selectedBuilder != nil && validateRequiredFields() && !isCreating
    }

    public func submit() async -> Bool {
        guard let builder = selectedBuilder, canSubmit else { return false }
        isCreating = true
        error = nil
        defer { isCreating = false }

        let draft = ResourceDraft(
            groupId: group.id,
            resourceType: builder.resourceType,
            basicFields: basicFields,
            enabledCapabilities: Array(enabledCapabilities),
            capabilityConfigs: [:],
            seriesPattern: nil,
            initialRules: []
        )

        do {
            let result = try await builder.build(draft)
            createdResourceId = result.resourceId
            log.debug("created \(builder.displayName) \(result.resourceId)")
            return true
        } catch let e as ResourceBuilderError {
            self.error = userFacing(error: e)
            return false
        } catch {
            self.error = "No pudimos crear el recurso: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Helpers

    private func validateRequiredFields() -> Bool {
        guard let builder = selectedBuilder else { return false }
        for field in builder.requiredFields {
            if let value = basicFields[field.key] {
                if case let .string(s) = value, s.trimmingCharacters(in: .whitespaces).isEmpty {
                    return false
                }
            } else {
                return false
            }
        }
        return true
    }

    private func defaultCapabilitiesFor(_ builder: any ResourceBuilder) -> Set<String> {
        // For events: rsvp + check_in + rotation default ON if the group has those modules.
        // For other types: empty default — user opts in explicitly.
        if builder.resourceType == .event {
            let available = Set(resolver.availableCapabilities(
                for: .event, in: group, catalog: catalog
            ))
            var defaults: Set<String> = []
            for id in ["rsvp", "check_in", "rotation"] where available.contains(id) {
                defaults.insert(id)
            }
            return defaults
        }
        return []
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
