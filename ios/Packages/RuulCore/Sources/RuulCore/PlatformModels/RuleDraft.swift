import Foundation

/// One use of a `RuleShape` inside a `RuleDraft`: the shape's id plus
/// the per-instance config the user filled in. The config conforms to
/// the shape's declared `config_fields` schema (validated server-side
/// by `publish_rule_composition`, mig 00245).
///
/// Pure value type — easy to diff, copy, persist, share. The composer
/// builds up a draft of these and the publish step serializes them
/// straight into the RPC payload.
public struct ShapeInstance: Codable, Sendable, Hashable, Identifiable {
    /// Stable instance id used for SwiftUI ForEach + drag-reorder.
    /// Server doesn't see this — it's only meaningful in-app.
    public var id: UUID
    public let shapeId: String
    public var config: JSONConfig
    /// Optional target selector for the consequence (§22.3 / mig 00249).
    /// Only meaningful when this ShapeInstance is a CONSEQUENCE in the
    /// draft; ignored on triggers / conditions / exceptions. Vocabulary:
    ///   nil / "$trigger.actor" → default (original target)
    ///   "$resource.host"       → resource's host_member_id
    ///   "$role.<role_id>"      → multiplex per holder of that role
    public var target: String?

    public init(shapeId: String, config: JSONConfig = .object([:]), target: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.shapeId = shapeId
        self.config = config
        self.target = target
    }

    public enum CodingKeys: String, CodingKey {
        case shapeId = "shape_id"
        case config
        case target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.shapeId = try c.decode(String.self, forKey: .shapeId)
        self.config  = try c.decodeIfPresent(JSONConfig.self, forKey: .config) ?? .object([:])
        self.target  = try c.decodeIfPresent(String.self, forKey: .target)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shapeId, forKey: .shapeId)
        try c.encode(config, forKey: .config)
        if let target { try c.encode(target, forKey: .target) }
    }
}

/// A rule under construction. The composer builds these from scratch
/// (free composition) or seeded from a template / existing rule
/// ("start from an example"). On publish, it's serialized into the
/// `publish_rule_composition` RPC (mig 00245).
///
/// Validation invariants (also enforced server-side):
///   - name: 2+ chars trimmed
///   - trigger: exactly one (nil = draft incomplete)
///   - conditions: 0..N, AND-chained
///   - consequences: 1+ (at least one effect — a rule with no effect
///     is just a comment)
public struct RuleDraft: Sendable, Hashable {
    public var name: String
    public var scope: RuleTemplateScope
    public var trigger: ShapeInstance?
    public var conditions: [ShapeInstance]
    public var consequences: [ShapeInstance]
    /// AND/OR/NOT tree of conditions when the composer is in
    /// "Avanzado" mode (§22.4 / mig 00251). When nil, the flat
    /// `conditions` list is the source of truth (legacy Simple mode,
    /// implicit AND). When non-nil, this is the source of truth and
    /// the wire payload sends the tree; `conditions` is kept in sync
    /// as the flat pre-order leaves view so legacy consumers
    /// (RuleSentenceFormatter, slug preview, allLeaves walkers)
    /// continue working unchanged.
    ///
    /// The composer's `enterAdvancedMode` lifts `conditions` into a
    /// fresh `.and([leaves])` tree; `exitAdvancedMode` flattens back
    /// to `nil` when safe (tree is just `.and([only leaves])`) or
    /// asks the user to confirm structure loss otherwise.
    public var conditionsTree: ShapeNode?
    /// Condition-shaped predicates that BLOCK consequences when ANY
    /// evaluates true on the target. Engine evaluates exceptions
    /// AFTER conditions pass, BEFORE consequences fire (mig 00248).
    /// Honors Constitution §18 (Talmud "regla y excepción") and §22.2
    /// Governance.md. Empty = no exceptions = old behavior.
    public var exceptions: [ShapeInstance]
    /// Membership filter — orthogonal axis to scope (§22.5 / mig 00250).
    /// When non-nil, the engine restricts targets to this single
    /// member. Useful for "Isaac está fuera de rotativa" style
    /// deviations that coexist with group/series/resource scope.
    /// Stored as the `group_members.id` UUID.
    public var membershipFilter: UUID?
    public var changeReason: String

    /// Stable identifier for this rule. Honors Constitution §7 and
    /// Social-Primitives §7 — rules need IDs that don't change with
    /// copy localization. When nil, the server auto-derives
    /// `<trigger_snake>_<first_cons_snake>_<6hex>` and returns the
    /// final value in `RuleVersionPublishResult.slug`. When set, must
    /// match `[a-z][a-z0-9_]{0,63}` and be unique within the group
    /// (server enforces both, mig 00246).
    public var slug: String?

    public init(
        name: String = "",
        scope: RuleTemplateScope = .group,
        trigger: ShapeInstance? = nil,
        conditions: [ShapeInstance] = [],
        consequences: [ShapeInstance] = [],
        exceptions: [ShapeInstance] = [],
        membershipFilter: UUID? = nil,
        changeReason: String = "",
        slug: String? = nil,
        conditionsTree: ShapeNode? = nil
    ) {
        self.name = name
        self.scope = scope
        self.trigger = trigger
        self.conditions = conditions
        self.consequences = consequences
        self.exceptions = exceptions
        self.membershipFilter = membershipFilter
        self.changeReason = changeReason
        self.slug = slug
        self.conditionsTree = conditionsTree
    }

    /// Preview of the slug the server would auto-derive if the draft
    /// publishes without an explicit one. Mirrors the SQL formula in
    /// mig 00246: `<trigger_snake>_<first_cons_snake>_…` (sans the
    /// random suffix — the random part is unknowable client-side).
    /// Returns nil when the draft has no trigger or no consequence yet.
    /// Used by the composer to show "tu acuerdo se guardará como X_…".
    public var suggestedSlugStem: String? {
        guard let triggerId = trigger?.shapeId else { return nil }
        guard let firstConsId = consequences.first?.shapeId else { return nil }
        return RuleDraft.slugifyCamel(triggerId) + "_" + RuleDraft.slugifyCamel(firstConsId)
    }

    /// Pure helper: camelCase → snake_case. Mirrors the SQL
    /// `slugify_camel` function so the iOS-side suggestion matches the
    /// server-side derivation exactly.
    public static func slugifyCamel(_ input: String) -> String {
        guard !input.isEmpty else { return "" }
        var result = ""
        for (i, ch) in input.enumerated() {
            if ch.isUppercase && i > 0 {
                result.append("_")
            }
            result.append(ch.lowercased())
        }
        return result
    }

    /// True when the draft satisfies the server's invariants — what the
    /// composer's "Publicar" button gates on.
    public var isPublishable: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= 2 else { return false }
        guard trigger != nil else { return false }
        guard !consequences.isEmpty else { return false }
        return true
    }

    // MARK: Mutations

    public mutating func setTrigger(_ shapeId: String, config: JSONConfig = .object([:])) {
        if let existing = trigger, existing.shapeId == shapeId {
            // Same shape — preserve config.
            return
        }
        trigger = ShapeInstance(shapeId: shapeId, config: config)
    }

    public mutating func addCondition(_ shapeId: String, config: JSONConfig = .object([:])) {
        let instance = ShapeInstance(shapeId: shapeId, config: config)
        conditions.append(instance)
        // §22.4: when the composer is in Avanzado mode, mirror the
        // addition into the tree's top-level AND so the structure
        // stays in sync. New leaves always land under the root AND
        // (the user can then wrap them as OR / NOT explicitly).
        if let tree = conditionsTree {
            conditionsTree = Self.appendingLeafAtRoot(tree, leaf: instance)
        }
    }

    public mutating func removeCondition(id: UUID) {
        conditions.removeAll { $0.id == id }
        // §22.4: keep the tree in lockstep — drop the matching leaf
        // anywhere it sits, collapsing the parent op when it becomes
        // empty or single-child.
        if let tree = conditionsTree {
            conditionsTree = tree.removing(id: id) ?? .and(id: UUID(), children: [])
        }
    }

    // MARK: §22.4 — Avanzado mode mutations

    /// Wraps the leaf with the given id in a `NOT` node. No-op when
    /// the id isn't in the tree or the user isn't in Avanzado mode
    /// (tree is nil — call `enterAdvancedMode` first).
    public mutating func wrapAsNOT(id: UUID) {
        guard let tree = conditionsTree else { return }
        guard let target = Self.findNode(in: tree, id: id) else { return }
        let wrapped: ShapeNode = .not(id: UUID(), child: target)
        conditionsTree = tree.replacing(id: id, with: wrapped) ?? tree
    }

    /// Wraps two sibling leaves (the target + the next sibling after
    /// it under the same parent) in a fresh `OR` node. The composer
    /// uses this for the "Combinar con siguiente como O" action so
    /// the user can express `A AND (B OR C)` by selecting B then
    /// merging C in. No-op when the target has no next sibling or
    /// the tree isn't in Avanzado mode.
    public mutating func wrapSiblingsAsOR(headId: UUID) {
        guard let tree = conditionsTree else { return }
        guard let (parentId, siblings) = Self.findSiblings(in: tree, of: headId) else { return }
        guard let headIdx = siblings.firstIndex(where: { $0.id == headId }) else { return }
        guard headIdx + 1 < siblings.count else { return }
        let next = siblings[headIdx + 1]
        let head = siblings[headIdx]
        var newSiblings = siblings
        newSiblings.removeSubrange(headIdx...(headIdx + 1))
        let orNode: ShapeNode = .or(id: UUID(), children: [head, next])
        newSiblings.insert(orNode, at: headIdx)
        // Replace the parent with the rebuilt siblings list.
        guard let parentNode = Self.findNode(in: tree, id: parentId) else { return }
        let rebuiltParent: ShapeNode
        switch parentNode {
        case .and(let id, _): rebuiltParent = .and(id: id, children: newSiblings)
        case .or(let id, _):  rebuiltParent = .or(id: id, children: newSiblings)
        case .not, .leaf:     return  // siblings only exist under AND/OR
        }
        conditionsTree = tree.replacing(id: parentId, with: rebuiltParent) ?? tree
    }

    /// Removes the op wrapping at `nodeId` and lifts its children one
    /// level up (under the wrapper's parent). For `NOT`, the single
    /// inner child replaces the NOT in place. For `AND`/`OR`, the
    /// children inline into the parent's children. No-op on leaves.
    public mutating func unwrap(nodeId: UUID) {
        guard let tree = conditionsTree else { return }
        guard let node = Self.findNode(in: tree, id: nodeId) else { return }
        switch node {
        case .leaf:
            return
        case .not(_, let child):
            conditionsTree = tree.replacing(id: nodeId, with: child) ?? tree
        case .and(_, let children), .or(_, let children):
            // Replace the wrapper with its children inline. If the
            // wrapper is the root, demote to a fresh AND wrapping the
            // children (the root must be a single node).
            if tree.id == nodeId {
                conditionsTree = .and(id: UUID(), children: children)
                return
            }
            guard let (parentId, siblings) = Self.findSiblings(in: tree, of: nodeId) else { return }
            guard let idx = siblings.firstIndex(where: { $0.id == nodeId }) else { return }
            var newSiblings = siblings
            newSiblings.remove(at: idx)
            newSiblings.insert(contentsOf: children, at: idx)
            guard let parentNode = Self.findNode(in: tree, id: parentId) else { return }
            let rebuiltParent: ShapeNode
            switch parentNode {
            case .and(let id, _): rebuiltParent = .and(id: id, children: newSiblings)
            case .or(let id, _):  rebuiltParent = .or(id: id, children: newSiblings)
            case .not, .leaf:     return
            }
            conditionsTree = tree.replacing(id: parentId, with: rebuiltParent) ?? tree
        }
    }

    /// Toggle `AND ⇄ OR` on the op node with the given id. Composer
    /// surface for "Cambiar agrupación: Y ⇄ O". No-op on leaves /
    /// NOT.
    public mutating func toggleAndOr(nodeId: UUID) {
        guard let tree = conditionsTree else { return }
        guard let node = Self.findNode(in: tree, id: nodeId) else { return }
        let swapped: ShapeNode
        switch node {
        case .and(let id, let cs): swapped = .or(id: id, children: cs)
        case .or(let id, let cs):  swapped = .and(id: id, children: cs)
        case .not, .leaf:          return
        }
        conditionsTree = tree.replacing(id: nodeId, with: swapped) ?? tree
    }

    /// Lifts the flat `conditions` list into a fresh `.and([leaves])`
    /// tree and writes it to `conditionsTree`. Idempotent — calling
    /// again on a draft already in Avanzado mode is a no-op.
    public mutating func enterAdvancedMode() {
        guard conditionsTree == nil else { return }
        conditionsTree = .and(conditions)
    }

    /// Drops the tree and reverts to the flat `conditions` list. The
    /// caller MUST verify `conditionsTree?.isFlatAnd == true` first
    /// (or accept the structure loss) — this method just flattens
    /// `allLeaves` and clears the tree.
    public mutating func exitAdvancedMode() {
        guard let tree = conditionsTree else { return }
        conditions = tree.allLeaves
        conditionsTree = nil
    }

    // MARK: Tree helpers (static — pure functions, easy to unit-test)

    private static func appendingLeafAtRoot(_ tree: ShapeNode, leaf: ShapeInstance) -> ShapeNode {
        switch tree {
        case .and(let id, let cs):
            return .and(id: id, children: cs + [.leaf(leaf)])
        default:
            // Root isn't an AND (rare — user wrapped everything in OR
            // or NOT). Demote to a fresh AND containing the old root
            // plus the new leaf so the leaf shows up somewhere
            // predictable.
            return .and(id: UUID(), children: [tree, .leaf(leaf)])
        }
    }

    private static func findNode(in tree: ShapeNode, id targetId: UUID) -> ShapeNode? {
        if tree.id == targetId { return tree }
        switch tree {
        case .leaf:
            return nil
        case .and(_, let cs), .or(_, let cs):
            for child in cs {
                if let hit = findNode(in: child, id: targetId) { return hit }
            }
            return nil
        case .not(_, let child):
            return findNode(in: child, id: targetId)
        }
    }

    /// Returns the parent's id + the parent's children array if
    /// `childId` sits directly under an AND/OR. Returns nil for the
    /// root, for nodes under NOT (which only has one child), or for
    /// ids not present in the tree.
    private static func findSiblings(in tree: ShapeNode, of childId: UUID) -> (UUID, [ShapeNode])? {
        switch tree {
        case .leaf:
            return nil
        case .and(let id, let cs), .or(let id, let cs):
            if cs.contains(where: { $0.id == childId }) {
                return (id, cs)
            }
            for child in cs {
                if let hit = findSiblings(in: child, of: childId) { return hit }
            }
            return nil
        case .not(_, let child):
            return findSiblings(in: child, of: childId)
        }
    }

    public mutating func addConsequence(_ shapeId: String, config: JSONConfig = .object([:])) {
        consequences.append(ShapeInstance(shapeId: shapeId, config: config))
    }

    public mutating func removeConsequence(id: UUID) {
        consequences.removeAll { $0.id == id }
    }

    public mutating func addException(_ shapeId: String, config: JSONConfig = .object([:])) {
        exceptions.append(ShapeInstance(shapeId: shapeId, config: config))
    }

    public mutating func removeException(id: UUID) {
        exceptions.removeAll { $0.id == id }
    }

    /// Set or clear the membership filter (§22.5). Pass nil to remove
    /// the filter — the rule then applies to every member matching the
    /// trigger/scope. Pass a `group_members.id` UUID to restrict
    /// targets to that single member.
    public mutating func setMembershipFilter(_ membershipId: UUID?) {
        membershipFilter = membershipId
    }

    /// Sets the target selector on the consequence with the given id.
    /// Pass nil or "$trigger.actor" to fall back to default. No-op for
    /// trigger / conditions / exceptions (they don't carry targets).
    public mutating func setConsequenceTarget(id: UUID, target: String?) {
        guard let i = consequences.firstIndex(where: { $0.id == id }) else { return }
        let normalized: String?
        if let t = target?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != "$trigger.actor" {
            normalized = t
        } else {
            normalized = nil
        }
        consequences[i].target = normalized
    }

    public mutating func updateConfig(forShapeInstanceId instanceId: UUID, key: String, value: JSONConfig) {
        func patch(_ instance: inout ShapeInstance) {
            guard case .object(var dict) = instance.config else {
                instance.config = .object([key: value])
                return
            }
            dict[key] = value
            instance.config = .object(dict)
        }
        if let i = conditions.firstIndex(where: { $0.id == instanceId }) {
            patch(&conditions[i])
            return
        }
        if let i = consequences.firstIndex(where: { $0.id == instanceId }) {
            patch(&consequences[i])
            return
        }
        if let i = exceptions.firstIndex(where: { $0.id == instanceId }) {
            patch(&exceptions[i])
            return
        }
        if var t = trigger, t.id == instanceId {
            patch(&t)
            trigger = t
        }
    }
}

// MARK: - Seeding from templates / existing rules

extension RuleDraft {
    /// Seed a draft from a curated template — the "start from an
    /// example" path. The user can freely edit / remove pieces after
    /// (the draft is no longer tied to the template).
    public static func from(
        template: RuleBuilderTemplate,
        scope: RuleTemplateScope
    ) -> RuleDraft {
        let triggerInstance = ShapeInstance(
            shapeId: template.composition.triggerShapeId,
            config: template.defaultParams
        )
        let conditions = template.composition.conditionShapeIds.map { id in
            ShapeInstance(shapeId: id, config: template.defaultParams)
        }
        let consequences = template.composition.consequenceShapeIds.map { id in
            ShapeInstance(shapeId: id, config: template.defaultParams)
        }
        return RuleDraft(
            name: template.displayNameES,
            scope: scope,
            trigger: triggerInstance,
            conditions: conditions,
            consequences: consequences
        )
    }

    /// Seed a draft from an existing published rule — the edit-in-place
    /// path. Preserves the rule's slug + scope + name + composition so
    /// `bumpRuleVersion` can publish the modified draft as version N+1
    /// of the SAME rule_id (closing §22.1 of Governance.md).
    ///
    /// Lossiness: `GroupRule.ConsequenceEnvelope.Config` is a typed
    /// view-model struct (amount / baseAmount / stepAmount / stepMinutes)
    /// — only the fine-shape's config fields are preserved through that
    /// type. For non-fine consequences whose extra config fields the
    /// view-model dropped, the composer will show the shape with its
    /// defaults; the user can re-set them before bumping. For Beta 1
    /// where the vast majority of consequences are `fine`, this is
    /// sufficient. A follow-up could fetch the canonical compiled jsonb
    /// from `rule_versions` to eliminate the lossiness.
    public static func from(rule: GroupRule) -> RuleDraft {
        let triggerInstance = ShapeInstance(
            shapeId: rule.trigger.eventType.rawString,
            config: rule.trigger.config
        )
        let conditions = rule.conditions.map { c in
            ShapeInstance(shapeId: c.type.rawString, config: c.config)
        }
        let consequences = rule.consequences.compactMap { env -> ShapeInstance? in
            guard let typeName = env.type else { return nil }
            return ShapeInstance(
                shapeId: typeName,
                config: reconstructConfig(from: env.config),
                target: env.target
            )
        }
        let exceptions = rule.exceptions.map { c in
            ShapeInstance(shapeId: c.type.rawString, config: c.config)
        }
        let scope = scopeFrom(rule: rule)
        // §22.4: preserve the tree when the rule was published with
        // OR/NOT structure (rule.conditionsTree is non-nil). For
        // pre-§22.4 rules (flat array on wire), `conditionsTree`
        // stays nil so the composer opens in Simple mode.
        let tree = treeFrom(rule: rule, fallbackLeaves: conditions)
        return RuleDraft(
            name: rule.name,
            scope: scope,
            trigger: triggerInstance,
            conditions: conditions,
            consequences: consequences,
            exceptions: exceptions,
            membershipFilter: rule.membershipId,
            slug: rule.slug,
            conditionsTree: tree
        )
    }

    /// Maps a `GroupRule`'s `conditionsTree` (engine-side ConditionNode
    /// of `RuleCondition` leaves) to the composer's `ShapeNode` (with
    /// `ShapeInstance` leaves). Returns nil when the rule was
    /// published as a flat array (no tree on the wire) — composer
    /// opens in Simple mode in that case.
    private static func treeFrom(rule: GroupRule, fallbackLeaves: [ShapeInstance]) -> ShapeNode? {
        guard let conditionTree = rule.conditionsTree else { return nil }
        // Use the same leaf identities the flat `conditions` view
        // exposes so the composer's edit handles match the rows.
        var leafCursor = fallbackLeaves.makeIterator()
        return convert(conditionTree, nextLeaf: { leafCursor.next() })
    }

    private static func convert(
        _ node: ConditionNode,
        nextLeaf: () -> ShapeInstance?
    ) -> ShapeNode {
        switch node {
        case .leaf:
            // The flat `fallbackLeaves` mirrors the pre-order leaves
            // of the same tree, so the next iterator value is the
            // ShapeInstance corresponding to this leaf. Fallback to a
            // fresh ShapeInstance if the iterator ran out (defensive
            // — only happens on stale data).
            if let instance = nextLeaf() {
                return .leaf(instance)
            }
            if case .leaf(let c) = node {
                return .leaf(ShapeInstance(shapeId: c.type.rawString, config: c.config))
            }
            return .leaf(ShapeInstance(shapeId: "alwaysTrue"))
        case .and(let children):
            return .and(id: UUID(), children: children.map { convert($0, nextLeaf: nextLeaf) })
        case .or(let children):
            return .or(id: UUID(), children: children.map { convert($0, nextLeaf: nextLeaf) })
        case .not(let child):
            return .not(id: UUID(), child: convert(child, nextLeaf: nextLeaf))
        }
    }

    private static func reconstructConfig(from cfg: GroupRule.ConsequenceEnvelope.Config?) -> JSONConfig {
        guard let cfg else { return .object([:]) }
        var dict: [String: JSONConfig] = [:]
        if let amount = cfg.amount             { dict["amount"]      = .int(amount) }
        if let baseAmount = cfg.baseAmount     { dict["baseAmount"]  = .int(baseAmount) }
        if let stepAmount = cfg.stepAmount     { dict["stepAmount"]  = .int(stepAmount) }
        if let stepMinutes = cfg.stepMinutes   { dict["stepMinutes"] = .int(stepMinutes) }
        return .object(dict)
    }

    private static func scopeFrom(rule: GroupRule) -> RuleTemplateScope {
        if let resourceId = rule.resourceId { return .resource(resourceId) }
        if let seriesId   = rule.seriesId   { return .series(seriesId) }
        return .group
        // membership + module scopes are §22.5 follow-ups — the picker
        // doesn't surface them yet, so when bumping a membership- or
        // module-scoped rule we fall through to group. The bump RPC
        // preserves the actual scope from the active rule_version's
        // compiled jsonb, so this draft-side scope is just the editor
        // hint; the persisted scope stays correct.
    }
}
