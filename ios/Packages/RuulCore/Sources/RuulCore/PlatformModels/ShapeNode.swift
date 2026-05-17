import Foundation

/// AND/OR/NOT composition of `ShapeInstance` leaves used by the
/// composer's "Avanzado" mode (§22.4 / mig 00251). Mirror of the
/// wire-side `ConditionNode` — the leaves carry author-side
/// `shape_id`+`config` (server uncompiled form) while the tree
/// structure matches what the server accepts under `p_conditions`.
///
/// Wire format the server consumes (publish_rule_composition v6,
/// bump_rule_version v5):
/// ```
/// // flat (when the user stays in Simple mode):
/// [{"shape_id":"…","config":{…}}, …]
/// // tree (Avanzado mode with at least one OR or NOT):
/// {"op":"and","children":[
///   {"shape_id":"a","config":{…}},
///   {"op":"or","children":[
///     {"shape_id":"b","config":{…}},
///     {"shape_id":"c","config":{…}}
///   ]}
/// ]}
/// ```
///
/// The `id: UUID` on op nodes is client-only — SwiftUI's `ForEach`
/// needs a stable identity for tree edits — and never round-trips to
/// the wire. Leaves use the `ShapeInstance.id` already on the value.
public indirect enum ShapeNode: Sendable, Hashable, Identifiable {
    case leaf(ShapeInstance)
    case and(id: UUID, children: [ShapeNode])
    case or(id: UUID, children: [ShapeNode])
    case not(id: UUID, child: ShapeNode)

    public var id: UUID {
        switch self {
        case .leaf(let i):     return i.id
        case .and(let id, _):  return id
        case .or(let id, _):   return id
        case .not(let id, _):  return id
        }
    }

    /// True when the node is the trivial empty AND. Used by the
    /// composer to short-circuit "no conditions" without inspecting
    /// cases.
    public var isEmpty: Bool {
        if case .and(_, let cs) = self { return cs.isEmpty }
        return false
    }

    /// All ShapeInstance leaves anywhere in the tree, pre-order. Used
    /// to populate the legacy flat `RuleDraft.conditions` view when
    /// the user toggles back to Simple mode.
    public var allLeaves: [ShapeInstance] {
        switch self {
        case .leaf(let i):      return [i]
        case .and(_, let cs):   return cs.flatMap(\.allLeaves)
        case .or(_, let cs):    return cs.flatMap(\.allLeaves)
        case .not(_, let c):    return c.allLeaves
        }
    }

    /// True when the tree carries no OR / NOT branches anywhere — the
    /// case where the Simple flat-list view is a lossless render. The
    /// composer uses this to decide whether the "Simple" toggle is
    /// safe (no warning) or destructive (would drop structure).
    public var isFlatAnd: Bool {
        if case .and(_, let cs) = self {
            return cs.allSatisfy { if case .leaf = $0 { return true } else { return false } }
        }
        return false
    }

    /// Convenience: wraps a flat leaf list under a fresh top-level AND.
    /// The shape the composer uses when entering Avanzado mode from a
    /// Simple draft.
    public static func and(_ leaves: [ShapeInstance]) -> ShapeNode {
        .and(id: UUID(), children: leaves.map(ShapeNode.leaf))
    }
}

// MARK: - Codable

extension ShapeNode: Codable {
    private enum TreeKey: String, CodingKey { case op, children }
    private enum LeafKey: String, CodingKey { case shapeId = "shape_id" }

    public init(from decoder: Decoder) throws {
        // Try leaf first — most common case and the bare shape on the wire.
        let single = try decoder.singleValueContainer()
        if let leaf = try? single.decode(ShapeInstance.self) {
            self = .leaf(leaf)
            return
        }
        // Tree node — `{op, children}` where op ∈ {and, or, not}.
        let keyed = try decoder.container(keyedBy: TreeKey.self)
        let op = try keyed.decode(String.self, forKey: .op)
        let children = try keyed.decodeIfPresent([ShapeNode].self, forKey: .children) ?? []
        switch op {
        case "and":
            self = .and(id: UUID(), children: children)
        case "or":
            self = .or(id: UUID(), children: children)
        case "not":
            // NOT carries exactly one child by server contract; tolerate
            // 0/many here so stale data doesn't crash the read path.
            self = .not(id: UUID(), child: children.first ?? .and(id: UUID(), children: []))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op,
                in: keyed,
                debugDescription: "Unknown shape-node op '\(op)' (expected and/or/not)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .leaf(let instance):
            // Bare ShapeInstance — the wire shape the server's
            // compile_condition_tree() consumes leaf-by-leaf.
            var single = encoder.singleValueContainer()
            try single.encode(instance)
        case .and(_, let children):
            var keyed = encoder.container(keyedBy: TreeKey.self)
            try keyed.encode("and", forKey: .op)
            try keyed.encode(children, forKey: .children)
        case .or(_, let children):
            var keyed = encoder.container(keyedBy: TreeKey.self)
            try keyed.encode("or", forKey: .op)
            try keyed.encode(children, forKey: .children)
        case .not(_, let child):
            var keyed = encoder.container(keyedBy: TreeKey.self)
            try keyed.encode("not", forKey: .op)
            try keyed.encode([child], forKey: .children)
        }
    }
}

// MARK: - Tree mutations

public extension ShapeNode {
    /// Replaces the first sub-node whose `id` matches with `replacement`.
    /// Returns nil when no match — caller can fall back to no-op.
    /// Used by the composer to apply edits without rebuilding the tree.
    func replacing(id targetId: UUID, with replacement: ShapeNode) -> ShapeNode? {
        if self.id == targetId { return replacement }
        switch self {
        case .leaf:
            return nil
        case .and(let id, let children):
            var changed = false
            let newChildren: [ShapeNode] = children.map { child in
                if let updated = child.replacing(id: targetId, with: replacement) {
                    changed = true
                    return updated
                }
                return child
            }
            return changed ? .and(id: id, children: newChildren) : nil
        case .or(let id, let children):
            var changed = false
            let newChildren: [ShapeNode] = children.map { child in
                if let updated = child.replacing(id: targetId, with: replacement) {
                    changed = true
                    return updated
                }
                return child
            }
            return changed ? .or(id: id, children: newChildren) : nil
        case .not(let id, let child):
            if let updated = child.replacing(id: targetId, with: replacement) {
                return .not(id: id, child: updated)
            }
            return nil
        }
    }

    /// Removes the first sub-node whose `id` matches. Composites that
    /// end up with `children.count < 1` after the removal collapse to
    /// `.and([])` so the tree never carries malformed nodes (the
    /// server validator rejects empty AND/OR). Returns nil when no
    /// match — caller can fall back to no-op.
    func removing(id targetId: UUID) -> ShapeNode? {
        if self.id == targetId { return nil }
        switch self {
        case .leaf:
            return nil
        case .and(let id, let children):
            return collapseRemoval(.and, id: id, children: children, targetId: targetId)
        case .or(let id, let children):
            return collapseRemoval(.or, id: id, children: children, targetId: targetId)
        case .not(let id, let child):
            if child.id == targetId {
                // NOT's only child removed → NOT collapses to empty AND.
                return .and(id: id, children: [])
            }
            if let updated = child.removing(id: targetId) {
                return .not(id: id, child: updated)
            }
            return nil
        }
    }

    private enum ContainerKind { case and, or }

    private func collapseRemoval(
        _ kind: ContainerKind,
        id: UUID,
        children: [ShapeNode],
        targetId: UUID
    ) -> ShapeNode? {
        var changed = false
        var newChildren: [ShapeNode] = []
        for child in children {
            if child.id == targetId {
                changed = true
                continue
            }
            if let updated = child.removing(id: targetId) {
                newChildren.append(updated)
                changed = true
            } else {
                newChildren.append(child)
            }
        }
        guard changed else { return nil }
        // Auto-collapse single-child AND/OR into the child — keeps the
        // tree minimal so the sentence renderer doesn't emit spurious
        // parens, and the server validator (which requires ≥1 child)
        // stays happy.
        if newChildren.count == 1 {
            return newChildren[0]
        }
        switch kind {
        case .and: return .and(id: id, children: newChildren)
        case .or:  return .or(id: id, children: newChildren)
        }
    }
}
