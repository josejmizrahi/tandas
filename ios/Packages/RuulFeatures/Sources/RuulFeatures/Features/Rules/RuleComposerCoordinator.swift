import Foundation
import Observation
import OSLog
import RuulCore

/// State + I/O for the free-composition Rule Composer.
///
/// Unlike `RuleBuilderCoordinator` (template wizard), this coordinator
/// holds a single editable `RuleDraft` and lets the user freely
/// add/remove pieces in any order. No phases — one screen, sections
/// that the user iterates over until the draft is publishable.
///
/// Flow:
///   1. Caller constructs with `init(group:, shapeRegistry:, repo:, scope:, resourceType:)`
///      or `init(group:, shapeRegistry:, repo:, draft:)` to start from
///      a seed (template or copied rule).
///   2. UI binds to `coordinator.draft.*` for live state.
///   3. UI calls mutation methods (`setTrigger`, `addCondition`,
///      `removeCondition`, …) to modify the draft.
///   4. UI gates "Publicar" on `coordinator.canPublish`.
///   5. UI calls `publish()` on tap; result lands in
///      `coordinator.publishResult` (Success) or
///      `coordinator.error` (Failure).
///
/// Compatibility filtering is enforced at the picker level:
/// `availableTriggers`, `availableConditions`, `availableConsequences`
/// return only shapes the catalog (rule_shapes) declares compatible
/// with the current `draft.scope` + resolved resource type.
/// Pickable target option for a consequence (§22.3 / mig 00249).
/// Mirrors the server vocabulary in `validate_consequence_target`:
/// `selector` is the literal string the server expects (or nil for
/// the default actor); `label` + `icon` drive the iOS picker.
public struct ConsequenceTargetOption: Identifiable, Hashable, Sendable {
    public var id: String { selector ?? "$trigger.actor" }
    public let selector: String?
    public let label: String
    public let icon: String

    public init(selector: String?, label: String, icon: String) {
        self.selector = selector
        self.label = label
        self.icon = icon
    }
}

@Observable @MainActor
public final class RuleComposerCoordinator: Identifiable {
    public nonisolated let id = UUID()

    /// The mutable draft. Bound directly to the view; mutations go
    /// through the helper methods on this coordinator to keep
    /// validation + side effects consistent.
    public private(set) var draft: RuleDraft

    public let group: Group
    public let shapeRegistry: RuleShapeRegistry
    public let resourceType: String?

    /// Roster of active members the composer surfaces in the membership
    /// filter picker (§22.5). When empty, the picker hides — caller
    /// didn't load it (e.g. preview / test contexts). Order is the
    /// caller's responsibility; the picker renders as-is.
    ///
    /// Initially empty; `loadAvailableMembers(using:)` populates it
    /// asynchronously when the composer view appears so the call sites
    /// don't have to fetch + await before constructing the coordinator.
    public private(set) var availableMembers: [MemberWithProfile]

    /// When non-nil, the composer is editing an existing rule in place:
    /// publish() routes to `bumpRuleVersion` (preserving rule_id +
    /// slug + scope) instead of `publishRuleComposition` (which creates
    /// a fresh rule). Set by the `init(group:…, editing:)` initializer.
    /// Closes §22.1 of Governance.md.
    public let editingRuleId: UUID?

    /// Optional list of curated templates the caller surfaces as
    /// starter examples. When empty, the composer hides the "Cargar
    /// ejemplo" action. The caller is responsible for filtering by
    /// resource_type before passing (the composer doesn't re-filter).
    public let starterTemplates: [RuleBuilderTemplate]

    public private(set) var isPublishing: Bool = false
    public private(set) var publishResult: RuleVersionPublishResult?
    public private(set) var error: String?

    private let repo: any RuleTemplateRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rule-composer")

    // MARK: Init

    public init(
        group: Group,
        shapeRegistry: RuleShapeRegistry,
        repo: any RuleTemplateRepository,
        scope: RuleTemplateScope,
        resourceType: String? = nil,
        starterTemplates: [RuleBuilderTemplate] = [],
        availableMembers: [MemberWithProfile] = []
    ) {
        self.group = group
        self.shapeRegistry = shapeRegistry
        self.repo = repo
        self.resourceType = resourceType
        self.starterTemplates = starterTemplates
        self.availableMembers = availableMembers
        self.editingRuleId = nil
        self.draft = RuleDraft(scope: scope)
    }

    /// Seed from a pre-populated draft (template-as-starting-point or
    /// copy-from-existing flow). The resource type comes from the
    /// caller because the draft itself only knows scope, not the
    /// underlying resource type.
    public init(
        group: Group,
        shapeRegistry: RuleShapeRegistry,
        repo: any RuleTemplateRepository,
        draft: RuleDraft,
        resourceType: String? = nil,
        starterTemplates: [RuleBuilderTemplate] = [],
        availableMembers: [MemberWithProfile] = []
    ) {
        self.group = group
        self.shapeRegistry = shapeRegistry
        self.repo = repo
        self.resourceType = resourceType
        self.starterTemplates = starterTemplates
        self.availableMembers = availableMembers
        self.editingRuleId = nil
        self.draft = draft
    }

    /// Open the composer in edit-in-place mode: seeded from an
    /// existing rule's composition, and publish() will bump the
    /// rule's version instead of creating a new one. The scope is
    /// preserved server-side from the rule's active rule_version
    /// (§22.1 / mig 00247) — the draft's scope is just an editor
    /// hint, not the persisted source of truth.
    public init(
        group: Group,
        shapeRegistry: RuleShapeRegistry,
        repo: any RuleTemplateRepository,
        editing rule: GroupRule,
        resourceType: String? = nil,
        availableMembers: [MemberWithProfile] = []
    ) {
        self.group = group
        self.shapeRegistry = shapeRegistry
        self.repo = repo
        self.resourceType = resourceType
        self.starterTemplates = []
        self.availableMembers = availableMembers
        self.editingRuleId = rule.id
        self.draft = RuleDraft.from(rule: rule)
    }

    /// Replace the current draft with one seeded from a curated
    /// template. The "start from an example" path — the user can edit
    /// freely after; the draft is no longer tied to the template.
    /// Preserves the current scope so a resource-scoped composer stays
    /// resource-scoped after seeding.
    public func loadStarterTemplate(_ template: RuleBuilderTemplate) {
        draft = RuleDraft.from(template: template, scope: draft.scope)
        error = nil
    }

    // MARK: Catalog options

    /// Triggers the user may pick for the current scope + resource type.
    /// Sorted by `sortOrder` then label.
    public var availableTriggers: [RuleShape] {
        let scopeKey = scopeKey(for: draft.scope)
        return shapeRegistry
            .shapes(kind: .trigger, scope: scopeKey, resourceType: resourceType)
            .sorted { ($0.sortOrder, $0.labelES) < ($1.sortOrder, $1.labelES) }
    }

    /// Conditions the user may add. Conditions don't filter by scope/
    /// resource type at the catalog level (they operate on the rule
    /// target, not the scope), so we return all `condition` shapes.
    public var availableConditions: [RuleShape] {
        shapeRegistry.shapes(of: .condition)
            .sorted { ($0.sortOrder, $0.labelES) < ($1.sortOrder, $1.labelES) }
    }

    /// Exceptions reuse the condition catalog — an exception IS a
    /// condition, just evaluated with inverted semantics (mig 00248).
    /// Identical list as `availableConditions`.
    public var availableExceptions: [RuleShape] {
        availableConditions
    }

    /// Consequences the user may add. Same rationale as conditions.
    public var availableConsequences: [RuleShape] {
        shapeRegistry.shapes(of: .consequence)
            .sorted { ($0.sortOrder, $0.labelES) < ($1.sortOrder, $1.labelES) }
    }

    public func shape(id: String) -> RuleShape? { shapeRegistry.shape(id: id) }

    public var canPublish: Bool {
        draft.isPublishable && !isPublishing
    }

    // MARK: Mutations

    public func setName(_ newValue: String) {
        draft.name = newValue
    }

    /// Admin-override of the auto-derived slug. Empty/whitespace falls
    /// back to nil so the server keeps auto-generating. Format
    /// validation happens server-side (mig 00246) on publish; iOS only
    /// trims here so the picker preview matches what gets sent.
    public func setSlug(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.slug = trimmed.isEmpty ? nil : trimmed
    }

    /// Preview of the slug the server will assign. Returns user's
    /// override if set; else the deterministic stem (without the
    /// random suffix that only the server knows); else nil when the
    /// trigger/consequence aren't picked yet.
    public var slugPreview: String? {
        if let custom = draft.slug { return custom }
        guard let stem = draft.suggestedSlugStem else { return nil }
        return stem + "_…"
    }

    public func setChangeReason(_ newValue: String) {
        draft.changeReason = newValue
    }

    public func setTrigger(shapeId: String) {
        // Replacing the trigger drops the previous one's config; seed
        // defaults for the new shape so the form opens with sensible
        // numbers.
        var seeded = ShapeInstance(shapeId: shapeId, config: defaultConfig(for: shapeId))
        seeded.id = draft.trigger?.id ?? seeded.id
        draft.trigger = seeded
    }

    public func clearTrigger() {
        draft.trigger = nil
    }

    public func addCondition(shapeId: String) {
        draft.addCondition(shapeId, config: defaultConfig(for: shapeId))
    }

    public func removeCondition(id: UUID) {
        draft.removeCondition(id: id)
    }

    public func addConsequence(shapeId: String) {
        draft.addConsequence(shapeId, config: defaultConfig(for: shapeId))
    }

    public func removeConsequence(id: UUID) {
        draft.removeConsequence(id: id)
    }

    public func addException(shapeId: String) {
        draft.addException(shapeId, config: defaultConfig(for: shapeId))
    }

    public func removeException(id: UUID) {
        draft.removeException(id: id)
    }

    // MARK: §22.4 — Avanzado mode (tree of conditions)

    /// True when the composer is in Avanzado mode (draft carries a
    /// non-nil `conditionsTree`). View binds the toggle to this.
    public var isAdvancedMode: Bool {
        draft.conditionsTree != nil
    }

    /// True when the tree carries OR / NOT structure — used by the
    /// view to warn the user before flipping back to Simple (which
    /// would flatten the tree and lose the structure).
    public var advancedHasStructure: Bool {
        guard let tree = draft.conditionsTree else { return false }
        return !tree.isFlatAnd
    }

    /// Lifts the flat condition list into a tree (`.and(leaves)`) so
    /// the user can author OR / NOT structure. Idempotent.
    public func enterAdvancedMode() {
        draft.enterAdvancedMode()
    }

    /// Drops the tree and reverts to the flat list. Caller MUST
    /// confirm with the user when `advancedHasStructure == true` —
    /// the leaves survive in the flat list but the OR/NOT wrapping
    /// is gone.
    public func exitAdvancedMode() {
        draft.exitAdvancedMode()
    }

    /// Wraps the leaf at `id` and the next sibling in a fresh OR
    /// node — the composer's "Combinar con siguiente como O" action.
    /// No-op when the leaf has no next sibling.
    public func wrapWithNextAsOR(id: UUID) {
        draft.wrapSiblingsAsOR(headId: id)
    }

    /// Wraps the node at `id` in a NOT — composer's "Marcar como
    /// excepción (NO)" action.
    public func wrapAsNOT(id: UUID) {
        draft.wrapAsNOT(id: id)
    }

    /// Removes the op wrapper at `id`, lifting its children one level
    /// up — composer's "Quitar agrupación" action.
    public func unwrapGrouping(id: UUID) {
        draft.unwrap(nodeId: id)
    }

    /// Flips AND ⇄ OR on the op node at `id` — composer's "Cambiar a
    /// Y / O" action.
    public func toggleAndOr(id: UUID) {
        draft.toggleAndOr(nodeId: id)
    }

    /// Sets the target selector on a specific consequence. See
    /// `ConsequenceTargetOption` for the Beta-1 vocabulary surfaced by
    /// `consequenceTargetOptions`.
    public func setConsequenceTarget(instanceId: UUID, selector: String?) {
        draft.setConsequenceTarget(id: instanceId, target: selector)
    }

    /// Targets the user can pick for a consequence. Always includes
    /// the default actor. Includes `$resource.host` when the draft's
    /// scope is .resource AND the resource is an event (only event
    /// metadata carries host_id today). Includes one entry per custom
    /// role declared in the group (excluding system founder/member —
    /// those are too broad as default targets).
    public var consequenceTargetOptions: [ConsequenceTargetOption] {
        var opts: [ConsequenceTargetOption] = [
            .init(selector: nil, label: "Al actor (quien disparó)", icon: "person.fill")
        ]
        if case .resource = draft.scope, resourceType == "event" {
            opts.append(.init(selector: "$resource.host", label: "Al anfitrión del evento", icon: "person.crop.square.badge.camera"))
        }
        for role in customRoles {
            opts.append(.init(
                selector: "$role.\(role.id)",
                label: "Al rol: \(role.humanLabel)",
                icon: "person.2.fill"
            ))
        }
        return opts
    }

    /// Human-readable label for a consequence's currently-set target.
    /// Falls back to the raw selector if the option is no longer in the
    /// catalog (role renamed, etc.).
    public func targetLabel(forSelector selector: String?) -> String {
        consequenceTargetOptions.first(where: { $0.selector == selector })?.label
            ?? selector
            ?? "Al actor (quien disparó)"
    }

    private var customRoles: [RoleDefinition] {
        // Read non-system roles from the group's roles jsonb. Founder +
        // member are system roles (broad scope) — we exclude them from
        // the picker to keep options curated. role.system flag comes
        // from the jsonb's "system": true marker in groups.roles.
        let all = group.roles?.values.map { $0 } ?? []
        return all
            .filter { !$0.system }
            .sorted { $0.humanLabel < $1.humanLabel }
    }

    public func updateConfig(forShapeInstanceId instanceId: UUID, key: String, value: JSONConfig) {
        draft.updateConfig(forShapeInstanceId: instanceId, key: key, value: value)
    }

    // MARK: Membership filter (§22.5 / mig 00250)

    /// Set or clear the membership filter. Pass nil to remove the filter
    /// (rule applies to every matching member); pass a `group_members.id`
    /// to restrict targets to that single member.
    public func setMembershipFilter(_ membershipId: UUID?) {
        draft.setMembershipFilter(membershipId)
    }

    /// Display name of a member by `group_members.id`. Used by the
    /// preview sentence + picker label so the formatter doesn't have to
    /// re-lookup. Returns nil when the id isn't in `availableMembers`.
    public func memberDisplayName(forMembershipId id: UUID) -> String? {
        availableMembers.first(where: { $0.member.id == id })?.displayName
    }

    /// Async loader called by the view's `.task` once the composer
    /// appears. Filters to active members only — the server rejects
    /// inactive memberships in `publish_rule_composition` (mig 00250),
    /// so surfacing them would just produce errors. No-op when called
    /// twice (avoids redundant fetches on re-appearance).
    public func loadAvailableMembers(using groupsRepo: any GroupsRepository) async {
        guard availableMembers.isEmpty else { return }
        do {
            let rows = try await groupsRepo.membersWithProfiles(of: group.id)
            availableMembers = rows
                .filter { $0.member.active }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            log.warning("composer membersWithProfiles failed: \(error.localizedDescription)")
        }
    }

    // MARK: Publish

    @discardableResult
    public func publish() async -> RuleVersionPublishResult? {
        guard canPublish else { return nil }
        isPublishing = true
        error = nil
        defer { isPublishing = false }
        do {
            let result: RuleVersionPublishResult
            if let ruleId = editingRuleId {
                // Edit-in-place: preserves rule_id, supersedes the
                // current version, inserts version+1 (§22.1, mig 00247).
                result = try await repo.bumpRuleVersion(ruleId: ruleId, draft: draft)
            } else {
                // Fresh composition: creates a new rule + version 1.
                result = try await repo.publishRuleComposition(groupId: group.id, draft: draft)
            }
            publishResult = result
            return result
        } catch {
            self.error = humanize(error: error)
            log.warning("composer publish failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Helpers

    /// Builds the default config for a freshly-picked shape by walking
    /// its `configFields` and using each field's `defaultValue` when
    /// present. Returns `.object([:])` when the shape has no defaults
    /// (the user fills everything by hand).
    private func defaultConfig(for shapeId: String) -> JSONConfig {
        guard let shape = shapeRegistry.shape(id: shapeId) else { return .object([:]) }
        var values: [String: JSONConfig] = [:]
        for field in shape.configFields {
            if let v = field.defaultValue {
                values[field.key] = v
            }
        }
        return .object(values)
    }

    private func scopeKey(for scope: RuleTemplateScope) -> String {
        switch scope {
        case .group:       return "group"
        case .resource:    return "resource"
        case .series:      return "series"
        }
    }

    private func humanize(error: Error) -> String {
        let raw = (error as NSError).localizedDescription.lowercased()
        if raw.contains("modifyrules") {
            return "No tienes permisos para crear reglas en este grupo."
        }
        if raw.contains("at least 2 characters") {
            return "El nombre debe tener al menos 2 caracteres."
        }
        if raw.contains("at least one consequence") {
            return "Agrega al menos una consecuencia."
        }
        if raw.contains("does not support scope") {
            return "El disparador elegido no aplica a este nivel (grupo / serie / instancia)."
        }
        if raw.contains("does not support resource_type") {
            return "El disparador elegido no aplica a este tipo de recurso."
        }
        if raw.contains("not found") {
            return "Una pieza de la regla ya no está disponible en el catálogo."
        }
        if raw.contains("no active version") {
            return "Esta regla está desactivada y no puede editarse desde aquí."
        }
        if raw.contains("already exists in this group") {
            return "Ya existe una regla con ese identificador en el grupo. Usa otro."
        }
        return "No pudimos guardar la regla. Intenta de nuevo."
    }
}
