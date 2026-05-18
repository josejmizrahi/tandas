import Foundation

/// Composable AND/OR/NOT tree of `RuleCondition` leaves.
///
/// Beta 1 stored rule conditions as a flat array, evaluated as an
/// implicit AND. §22.4 lifts that limitation: a rule can express
/// "A AND (B OR C) AND NOT D" in a single rule instead of forking
/// duplicates per branch.
///
/// Wire format (jsonb column `rules.conditions`):
///
/// - Legacy / simple — JSON array of leaves, treated as `.and(leaves)`:
///   ```json
///   [{"type": "responseStatusIs", "config": {...}}, ...]
///   ```
/// - Tree — `{op, children}` object with `op ∈ {and, or, not}`. Children
///   are themselves nodes (leaves OR nested ops):
///   ```json
///   {"op": "and", "children": [
///       {"type": "responseStatusIs", "config": {...}},
///       {"op": "or", "children": [
///           {"type": "checkInExists", "config": {...}},
///           {"type": "alwaysTrue",    "config": {}}
///       ]}
///   ]}
///   ```
///
/// Encoding round-trips back to the compact array form when the tree is
/// a single `.and` of `.leaf` children (the common case). Anything
/// richer encodes as `{op, children}`. Pre-§22.4 rules keep their wire
/// shape unchanged on persisted reads.
public indirect enum ConditionNode: Sendable, Hashable {
    case leaf(RuleCondition)
    case and([ConditionNode])
    case or([ConditionNode])
    case not(ConditionNode)

    /// Empty `.and([])` — semantically true (vacuous AND). The "no
    /// conditions" default.
    public static let empty: ConditionNode = .and([])
}

// MARK: - Walkers

public extension ConditionNode {
    /// Returns the flat list of leaves IFF the tree is a single AND of
    /// leaves (the simple/legacy case). Nil for richer trees — callers
    /// that need the full tree must walk it explicitly. Used by code
    /// paths that pre-date §22.4 (param extraction, debug renders).
    var flatLeaves: [RuleCondition]? {
        switch self {
        case .leaf(let c):
            return [c]
        case .and(let children):
            var out: [RuleCondition] = []
            out.reserveCapacity(children.count)
            for child in children {
                if case .leaf(let c) = child {
                    out.append(c)
                } else {
                    return nil
                }
            }
            return out
        case .or, .not:
            return nil
        }
    }

    /// All leaves anywhere in the tree, in left-to-right pre-order. For
    /// callers that only need the SET of conditions referenced (param
    /// extraction across the whole rule, capability checks) without
    /// caring about the AND/OR/NOT structure.
    var allLeaves: [RuleCondition] {
        switch self {
        case .leaf(let c):  return [c]
        case .and(let cs):  return cs.flatMap(\.allLeaves)
        case .or(let cs):   return cs.flatMap(\.allLeaves)
        case .not(let n):   return n.allLeaves
        }
    }

    /// True when the tree is the trivial empty AND. Lets simple paths
    /// short-circuit "no conditions" without inspecting cases.
    var isEmpty: Bool {
        if case .and(let cs) = self { return cs.isEmpty }
        return false
    }
}

// MARK: - Codable

extension ConditionNode: Codable {
    private enum TreeKey: String, CodingKey { case op, children }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        // Legacy wire shape is a JSON array — route pre-§22.4 rules
        // through `.and(.leaf, .leaf, …)` without touching the tree
        // branch.
        if let leaves = try? single.decode([RuleCondition].self) {
            self = .and(leaves.map(ConditionNode.leaf))
            return
        }
        // Bare leaf (no wrapping array or tree) — defensive: tolerate a
        // single object that looks like a RuleCondition. The engine
        // never emits this shape, but it keeps the decoder symmetric
        // with `allLeaves` round-trips.
        if let leaf = try? single.decode(RuleCondition.self) {
            self = .leaf(leaf)
            return
        }
        // Tree object: `{op, children}` where op ∈ {and, or, not}.
        let keyed = try decoder.container(keyedBy: TreeKey.self)
        let op = try keyed.decode(String.self, forKey: .op)
        let children = try keyed.decodeIfPresent([ConditionNode].self, forKey: .children) ?? []
        switch op {
        case "and":
            self = .and(children)
        case "or":
            self = .or(children)
        case "not":
            // `not` carries exactly one child. The server validator
            // enforces this; the decoder tolerates 0/1/many and picks
            // the first to avoid crashing on stale or future data.
            guard let only = children.first else {
                self = .not(.empty)
                return
            }
            self = .not(only)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op,
                in: keyed,
                debugDescription: "Unknown condition op '\(op)' (expected and/or/not)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Compact form for the common case: an AND of leaves encodes as
        // a JSON array so pre-§22.4 consumers (and `rule_versions.compiled`
        // snapshots) see the same shape they always saw. Gated on the
        // top-level case being `.and` because `flatLeaves` also matches
        // a bare `.leaf` — if we let the fast path swallow a leaf node,
        // the encoder writes `[c]` and the decoder reads it back as
        // `.and([.leaf(c)])`, breaking round-trip symmetry on nested
        // leaves inside `.or`/`.not`.
        if case .and = self, let leaves = flatLeaves {
            var single = encoder.singleValueContainer()
            try single.encode(leaves)
            return
        }
        switch self {
        case .leaf(let c):
            var single = encoder.singleValueContainer()
            try single.encode(c)
        case .and(let children):
            var keyed = encoder.container(keyedBy: TreeKey.self)
            try keyed.encode("and", forKey: .op)
            try keyed.encode(children, forKey: .children)
        case .or(let children):
            var keyed = encoder.container(keyedBy: TreeKey.self)
            try keyed.encode("or", forKey: .op)
            try keyed.encode(children, forKey: .children)
        case .not(let child):
            var keyed = encoder.container(keyedBy: TreeKey.self)
            try keyed.encode("not", forKey: .op)
            try keyed.encode([child], forKey: .children)
        }
    }
}

// MARK: - Backward-compat init from a flat list

public extension ConditionNode {
    /// Wraps a flat list of leaves as `.and(leaves)`. Used by callers
    /// that still hold `[RuleCondition]` (legacy templates, builder
    /// "simple" mode, tests). Mirrors the legacy "implicit AND"
    /// semantics so behavior is unchanged for pre-§22.4 paths.
    init(leaves: [RuleCondition]) {
        self = .and(leaves.map(ConditionNode.leaf))
    }
}
