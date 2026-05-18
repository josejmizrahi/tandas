import Foundation
import OSLog

/// State machine for the new 3-step resource creation flow
/// (Type → Variant → Identity → Create → Intents). Replaces
/// `ResourceWizardCoordinator` as the primary surface; the old wizard
/// stays behind `Governance → Advanced → "Crear con opciones avanzadas"`
/// for power users.
///
/// Doctrine 2026-05-18:
///   - Capabilities are invisible infrastructure. The coordinator
///     resolves them silently from the variant + template defaults at
///     create time; the user never sees a toggle.
///   - Silent-attach gate: variant.attachedCapabilities ∪
///     templateDefault, intersected with the group's available caps
///     (resolver) and the catalog's stable status. Anything missing is
///     dropped — never surfaced as an error.
///   - Post-create capability activation (intent-driven) flows through
///     `LazyCapabilityActivator`, not this coordinator. Intents are the
///     ONLY place caps come online after creation.
@Observable
@MainActor
public final class ResourceCreationCoordinator {

    // MARK: - Phase

    public enum Phase: Sendable, Equatable {
        case typePicker
        case variantPicker(type: ResourceType)
        case identity(type: ResourceType, variant: ResourceVariant)
        case creating
        case postCreate(resourceId: UUID, variant: ResourceVariant)
        case failed(message: String)
    }

    // MARK: - Dependencies (injected)

    public let group: Group
    public let builders: ResourceBuilderRegistry
    public let variants: ResourceVariantRegistry
    public let catalog: CapabilityCatalog
    public let resolver: CapabilityResolver

    /// Per-type silent-cap defaults coming from `templates.config.
    /// defaultCapabilities`. Union'd with `variant.attachedCapabilities`
    /// at submit time. Empty map = variant alone drives the silent set.
    public let templateDefaultsByType: [String: [String]]

    // MARK: - Mutable state

    public private(set) var phase: Phase = .typePicker

    /// User-filled identity fields. Keyed by `BuilderField.key`. Seeded
    /// with sensible defaults when a variant is picked (so the CTA
    /// validates immediately without forcing taps on the date picker).
    public var identityFields: [String: JSONConfig] = [:]

    /// Capability ids that ACTUALLY came online for the last successful
    /// create call. Populated in `.postCreate`; empty otherwise.
    /// Surfaced so the post-create intent screen can filter intents
    /// whose requiredCapabilities are now satisfied.
    public private(set) var attachedCapabilities: Set<String> = []

    // MARK: - Init

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "resource.creation")

    public init(
        group: Group,
        builders: ResourceBuilderRegistry,
        variants: ResourceVariantRegistry = DefaultResourceVariantRegistry.v1,
        catalog: CapabilityCatalog = .v1,
        resolver: CapabilityResolver = CapabilityResolver(),
        templateDefaultsByType: [String: [String]] = [:]
    ) {
        self.group = group
        self.builders = builders
        self.variants = variants
        self.catalog = catalog
        self.resolver = resolver
        self.templateDefaultsByType = templateDefaultsByType
    }

    // MARK: - Phase transitions

    /// Step 1 → Step 2. Records the chosen type so the variant picker
    /// can filter the registry. No-op if not currently on `.typePicker`.
    public func pickType(_ type: ResourceType) {
        guard case .typePicker = phase else { return }
        phase = .variantPicker(type: type)
    }

    /// Step 2 → Step 3. Records the chosen variant, seeds identity
    /// defaults from the builder's required fields so the CTA validates
    /// without forcing taps on the date picker / currency picker / etc.
    /// No-op if the variant's resourceType doesn't match the current
    /// phase's type (defensive).
    public func pickVariant(_ variant: ResourceVariant) {
        guard case .variantPicker(let type) = phase, variant.resourceType == type else {
            log.warning("pickVariant called in wrong phase or with type mismatch")
            return
        }
        seedIdentityDefaults(for: variant)
        phase = .identity(type: type, variant: variant)
    }

    /// Mutate one identity field. Use from form bindings (next sprint's
    /// `MinimalIdentityForm` writes here). Allowed at any phase but only
    /// takes effect when phase is `.identity`.
    public func setIdentityField(_ key: String, value: JSONConfig) {
        identityFields[key] = value
    }

    /// Walks one phase backward. Per phase:
    ///   - `.typePicker`            → no-op (already at start)
    ///   - `.variantPicker`         → back to `.typePicker`
    ///   - `.identity`              → back to `.variantPicker` (preserves type)
    ///   - `.creating`              → no-op (in flight; can't cancel mid-call)
    ///   - `.postCreate`            → no-op (commit happened; reset() to start over)
    ///   - `.failed`                → back to `.identity` so the user can fix + retry
    public func backOneStep() {
        switch phase {
        case .typePicker, .creating, .postCreate:
            return
        case .variantPicker:
            phase = .typePicker
            identityFields = [:]
        case .identity(let type, _):
            phase = .variantPicker(type: type)
        case .failed:
            // Need the last (type, variant) to return to identity. Pull
            // from a snapshot taken at create() entry.
            if let snap = lastIdentitySnapshot {
                phase = .identity(type: snap.type, variant: snap.variant)
            } else {
                phase = .typePicker
                identityFields = [:]
            }
        }
    }

    /// Full reset — back to step 1, clears identity + attachedCaps +
    /// snapshot. The post-create screen calls this when the user taps
    /// "Crear otro" or dismisses the success screen.
    public func reset() {
        phase = .typePicker
        identityFields = [:]
        attachedCapabilities = []
        lastIdentitySnapshot = nil
    }

    // MARK: - Create

    /// True when the current phase + identity field state is sufficient
    /// to call `create()`. The CTA's enabled-state binds here.
    public var canCreate: Bool {
        guard case .identity(let type, _) = phase,
              let builder = builders.builder(for: type) else { return false }
        for field in builder.requiredFields where !field.isOptional {
            // Optional-flag uses the same isFieldFilled semantics as the
            // legacy wizard so the two stay in sync.
            guard let value = identityFields[field.key] else { return false }
            switch value {
            case .null:
                return false
            case .string(let s) where s.trimmingCharacters(in: .whitespaces).isEmpty:
                return false
            case .string, .int, .double, .bool, .object, .array:
                continue
            }
        }
        return true
    }

    /// Commit the resource. Resolves the silent cap set, builds a
    /// `ResourceDraft`, hands off to the builder, and transitions:
    ///   - `.identity` → `.creating` → `.postCreate(id, variant)` on success
    ///   - `.identity` → `.creating` → `.failed(message)` on builder error
    ///
    /// Returns the new resource id on success, nil on failure (phase is
    /// the authoritative signal — return value is sugar for callers
    /// that want to bind something immediately).
    @discardableResult
    public func create() async -> UUID? {
        guard case .identity(let type, let variant) = phase else { return nil }
        guard let builder = builders.builder(for: type) else {
            phase = .failed(message: "No hay builder para \(type.humanLabel).")
            return nil
        }
        guard canCreate else { return nil }

        // Snapshot so backOneStep from .failed can restore identity.
        lastIdentitySnapshot = .init(type: type, variant: variant)
        phase = .creating

        let silentCaps = resolveSilentCapabilities(for: variant)
        let draft = ResourceDraft(
            groupId: group.id,
            resourceType: type,
            basicFields: identityFields,
            enabledCapabilities: Array(silentCaps).sorted(),
            capabilityConfigs: [:],     // identity-step caps need no config — that's the silent-attach contract
            seriesPattern: nil,         // recurrence sub-config arrives via intent or variant-specific identity (Sprint 2 leaves this to the legacy wizard / future variant override)
            initialRules: []            // rules attach via `add_rules` intent post-create, not at create
        )

        do {
            let result = try await builder.build(draft)
            attachedCapabilities = Set(result.enabledCapabilityIds)
            phase = .postCreate(resourceId: result.resourceId, variant: variant)
            return result.resourceId
        } catch let e as ResourceBuilderError {
            phase = .failed(message: userFacing(error: e))
            return nil
        } catch {
            phase = .failed(message: "No pudimos crear el recurso. \(error.ruulUserMessage)")
            return nil
        }
    }

    // MARK: - Silent capability resolution

    /// Computes the silent-attach set per doctrine 2026-05-18:
    /// `variant.attached ∪ templateDefault[type]`, filtered by:
    ///   1. Catalog membership (id resolves to a `CapabilityBlock`)
    ///   2. Stable status (`block.status.isStable`)
    ///   3. Resolver availability (group's active modules provide it
    ///      for the resource type)
    /// Anything not passing all three is silently dropped — the matching
    /// intent on the post-create screen handles the gap honestly by
    /// staying hidden until the cap promotes / module turns on.
    public func resolveSilentCapabilities(for variant: ResourceVariant) -> Set<String> {
        let templateIds = templateDefaultsByType[variant.resourceType.rawString] ?? []
        let union = variant.attachedCapabilities.union(templateIds)
        let available = Set(resolver.availableCapabilities(
            for: variant.resourceType, in: group, catalog: catalog
        ))
        return union.filter { id in
            guard let block = catalog[id] else { return false }
            return block.status.isStable && available.contains(id)
        }
    }

    // MARK: - Internals

    private struct IdentitySnapshot: Sendable {
        let type: ResourceType
        let variant: ResourceVariant
    }
    private var lastIdentitySnapshot: IdentitySnapshot?

    /// Seeds identityFields with sensible defaults for non-text fields
    /// so `canCreate` evaluates true immediately when the user only
    /// touches the title input. Mirrors the legacy
    /// `ResourceWizardCoordinator.selectBuilder` behavior so feel is
    /// identical when the user funnels through the new flow.
    private func seedIdentityDefaults(for variant: ResourceVariant) {
        identityFields = [:]
        guard let builder = builders.builder(for: variant.resourceType) else { return }
        let iso = ISO8601DateFormatter()
        let defaultDate = Date.now.addingTimeInterval(86_400)
        for field in builder.requiredFields {
            switch field.kind {
            case .date, .time, .dateTime, .duration:
                identityFields[field.key] = .string(iso.string(from: defaultDate))
            case .boolean:
                identityFields[field.key] = .bool(false)
            case .integer, .decimal, .currency, .money:
                identityFields[field.key] = .int(0)
            default:
                break   // text / picker / resourcePicker / memberPicker → wait for user input
            }
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
