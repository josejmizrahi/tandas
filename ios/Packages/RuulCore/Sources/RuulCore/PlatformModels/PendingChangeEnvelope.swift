import Foundation

/// Operation envelope persisted in `votes.payload` when a `rule_change` vote
/// is opened. Mirror of the SQL `apply_pending_change` dispatch (mig 00089):
/// the server reads `op` + `target_rule_id` + `after` from the same shape
/// this struct encodes.
///
/// Encoded JSON shape:
/// ```
/// {
///   "op": "rule.toggle",
///   "target_rule_id": "<uuid>" | null,
///   "before": {...},
///   "after":  {...}
/// }
/// ```
///
/// `before` / `after` carry the natural shape for the op so the UI can
/// render a diff without re-fetching state. Bodies are intentionally flat
/// (no nesting under the op name) so the SQL applier can read them with a
/// single `->> 'key'` lookup.
public struct PendingChangeEnvelope: Codable, Sendable, Hashable {
    public let op: TargetAction
    public let targetRuleId: UUID?
    public let before: AnyPayload?
    public let after: AnyPayload

    public init(op: TargetAction, targetRuleId: UUID?, before: AnyPayload?, after: AnyPayload) {
        self.op = op
        self.targetRuleId = targetRuleId
        self.before = before
        self.after = after
    }

    public enum CodingKeys: String, CodingKey {
        case op, before, after
        case targetRuleId = "target_rule_id"
    }

    // MARK: - Convenience constructors

    public static func ruleToggle(targetRuleId: UUID, before: ToggleBody, after: ToggleBody) -> Self {
        .init(op: .ruleToggle, targetRuleId: targetRuleId,
              before: AnyPayload(.toggle(before)),
              after:  AnyPayload(.toggle(after)))
    }

    public static func ruleUpdateAmount(targetRuleId: UUID, before: AmountBody, after: AmountBody) -> Self {
        .init(op: .ruleUpdateAmount, targetRuleId: targetRuleId,
              before: AnyPayload(.amount(before)),
              after:  AnyPayload(.amount(after)))
    }

    public static func ruleDelete(targetRuleId: UUID) -> Self {
        .init(op: .ruleDelete, targetRuleId: targetRuleId,
              before: nil,
              after:  AnyPayload(.empty))
    }

    public static func ruleCreate(after: CreateBody) -> Self {
        .init(op: .ruleCreate, targetRuleId: nil,
              before: nil,
              after:  AnyPayload(.create(after)))
    }

    // MARK: - Per-op bodies

    public struct ToggleBody: Codable, Sendable, Hashable {
        public let isActive: Bool
        public init(isActive: Bool) { self.isActive = isActive }
        public enum CodingKeys: String, CodingKey { case isActive = "is_active" }
    }

    public struct AmountBody: Codable, Sendable, Hashable {
        public let amount: Int
        public init(amount: Int) { self.amount = amount }
    }

    public struct CreateBody: Codable, Sendable, Hashable {
        public let name: String
        public let isActive: Bool
        public let resourceId: UUID?
        public let trigger: RuleTrigger
        public let conditions: [RuleCondition]
        public let consequences: [RuleConsequence]

        public init(
            name: String,
            isActive: Bool = true,
            resourceId: UUID? = nil,
            trigger: RuleTrigger,
            conditions: [RuleCondition],
            consequences: [RuleConsequence]
        ) {
            self.name = name
            self.isActive = isActive
            self.resourceId = resourceId
            self.trigger = trigger
            self.conditions = conditions
            self.consequences = consequences
        }

        public enum CodingKeys: String, CodingKey {
            case name, trigger, conditions, consequences
            case isActive   = "is_active"
            case resourceId = "resource_id"
        }
    }

    /// Type-erased wrapper so `before`/`after` can carry any per-op body
    /// while still encoding flat into the envelope (matching the SQL
    /// applier's expected shape).
    public struct AnyPayload: Codable, Sendable, Hashable {
        public enum Inner: Sendable, Hashable {
            case toggle(ToggleBody)
            case amount(AmountBody)
            case create(CreateBody)
            case empty
        }
        public let inner: Inner

        public init(_ inner: Inner) { self.inner = inner }

        public init(from decoder: Decoder) throws {
            // Tolerant decoding: try the richest shape first (create has the
            // most fields), then narrower ones, else empty.
            if let v = try? CreateBody(from: decoder) { self.inner = .create(v); return }
            if let v = try? AmountBody(from: decoder) { self.inner = .amount(v); return }
            if let v = try? ToggleBody(from: decoder) { self.inner = .toggle(v); return }
            self.inner = .empty
        }

        public func encode(to encoder: Encoder) throws {
            switch inner {
            case .toggle(let v): try v.encode(to: encoder)
            case .amount(let v): try v.encode(to: encoder)
            case .create(let v): try v.encode(to: encoder)
            case .empty:
                // Encode as an empty object so the SQL `v_after = payload->'after'`
                // read produces `'{}'::jsonb`, not null.
                var c = encoder.container(keyedBy: EmptyKey.self)
                _ = c
            }
        }

        private enum EmptyKey: CodingKey {}
    }
}
