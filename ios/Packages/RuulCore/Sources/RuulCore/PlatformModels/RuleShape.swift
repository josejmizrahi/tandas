import Foundation

/// A single trigger / condition / consequence the rule engine understands,
/// surfaced to the iOS rule builder as catalog metadata. Loaded from
/// `public.rule_shapes` via the `list_rule_shapes()` RPC at app boot,
/// mirroring how `ModuleRegistry` consumes `list_modules`.
///
/// Founder principle 2026-05-10: rule shapes are runtime-declarative. No
/// hardcoded Swift enums for triggers/consequences — the form renders
/// from this catalog. Adding a shape = INSERT into `rule_shapes` + a
/// server-side evaluator. No client release.
public struct RuleShape: Identifiable, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case trigger
        case condition
        case consequence
    }

    public let id: String
    public let kind: Kind
    /// User-facing Spanish label rendered in pickers/sentences. Read-only;
    /// catalog updates must be done server-side.
    public let labelES: String
    /// Optional longer hint shown as a row subtitle.
    public let summaryES: String?
    /// SF Symbol name for picker rows. Optional — coordinator/view fall
    /// back to a generic icon when absent.
    public let icon: String?
    /// Scope levels this shape may be attached to. Empty array = applies
    /// universally. Conditions/consequences typically leave this empty
    /// because they're orthogonal to the scope where the rule lives.
    public let validScopes: [String]
    /// Resource types this shape applies to (e.g. `["event"]`). Empty =
    /// applies to all resource types or to group scope.
    public let validResourceTypes: [String]
    /// Form fields the iOS builder should render when this shape is the
    /// active pick. Empty = no extra inputs needed beyond selecting the
    /// shape.
    public let configFields: [RuleShapeField]
    public let sortOrder: Int

    public enum CodingKeys: String, CodingKey {
        case id, kind, icon
        case labelES            = "label_es"
        case summaryES          = "summary_es"
        case validScopes        = "valid_scopes"
        case validResourceTypes = "valid_resource_types"
        case configFields       = "config_fields"
        case sortOrder          = "sort_order"
    }

    public init(
        id: String,
        kind: Kind,
        labelES: String,
        summaryES: String? = nil,
        icon: String? = nil,
        validScopes: [String] = [],
        validResourceTypes: [String] = [],
        configFields: [RuleShapeField] = [],
        sortOrder: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.labelES = labelES
        self.summaryES = summaryES
        self.icon = icon
        self.validScopes = validScopes
        self.validResourceTypes = validResourceTypes
        self.configFields = configFields
        self.sortOrder = sortOrder
    }
}

/// One configurable input on a rule shape. Drives dynamic form rendering
/// in the iOS rule builder. Mirrors the `config_fields` jsonb element
/// stored in `public.rule_shapes.config_fields`.
public struct RuleShapeField: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case int
        case string
        /// Currency in cents-equivalent (V1: MXN whole units). UI surfaces
        /// a numeric keyboard + currency suffix.
        case currency
        /// Future: enum picker, duration, member picker. Skipped for V1.
    }

    public let key: String
    public let kind: Kind
    public let labelES: String
    public let placeholder: String?
    /// Optional default applied to the form when the user picks the shape.
    /// Decoded as a JSONConfig so any of int/string/currency works.
    public let defaultValue: JSONConfig?
    public let min: Int?
    public let max: Int?
    public let optional: Bool

    public enum CodingKeys: String, CodingKey {
        case key, kind, placeholder, min, max, optional
        case labelES      = "label_es"
        case defaultValue = "defaultValue"
    }

    public init(
        key: String,
        kind: Kind,
        labelES: String,
        placeholder: String? = nil,
        defaultValue: JSONConfig? = nil,
        min: Int? = nil,
        max: Int? = nil,
        optional: Bool = false
    ) {
        self.key = key
        self.kind = kind
        self.labelES = labelES
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.optional = optional
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key         = try c.decode(String.self, forKey: .key)
        self.kind        = try c.decode(Kind.self, forKey: .kind)
        self.labelES     = try c.decode(String.self, forKey: .labelES)
        self.placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        self.defaultValue = try c.decodeIfPresent(JSONConfig.self, forKey: .defaultValue)
        self.min         = try c.decodeIfPresent(Int.self, forKey: .min)
        self.max         = try c.decodeIfPresent(Int.self, forKey: .max)
        self.optional    = (try? c.decodeIfPresent(Bool.self, forKey: .optional)) ?? false
    }
}

/// In-memory registry holding the loaded rule shape catalog. Mirrors the
/// `ModuleRegistry` pattern — refreshed at boot, filterable by kind +
/// scope + resource type. The Live repo populates this; mocks/tests can
/// build it inline.
public struct RuleShapeRegistry: Sendable, Hashable {
    public let shapes: [RuleShape]

    public init(shapes: [RuleShape]) {
        self.shapes = shapes
    }

    public func shapes(of kind: RuleShape.Kind) -> [RuleShape] {
        shapes.filter { $0.kind == kind }
    }

    public func shape(id: String) -> RuleShape? {
        shapes.first(where: { $0.id == id })
    }

    /// Triggers/conditions/consequences applicable to a given scope +
    /// resource type. Empty arrays in the shape mean "any" — those rows
    /// always pass.
    public func shapes(
        kind: RuleShape.Kind,
        scope: String?,
        resourceType: String?
    ) -> [RuleShape] {
        shapes.filter { shape in
            guard shape.kind == kind else { return false }
            if let scope, !shape.validScopes.isEmpty,
               !shape.validScopes.contains(scope) {
                return false
            }
            if let resourceType, !shape.validResourceTypes.isEmpty,
               !shape.validResourceTypes.contains(resourceType) {
                return false
            }
            return true
        }
    }

    /// Cold-start fallback used before `list_rule_shapes` returns. Keeps
    /// the V1 surface usable offline / pre-auth. Server is the source of
    /// truth; this is just enough for the form to render something
    /// reasonable.
    public static let v1Fallback = RuleShapeRegistry(shapes: [
        RuleShape(
            id: "checkInRecorded",
            kind: .trigger,
            labelES: "Cuando alguien llega tarde",
            summaryES: "Se dispara cuando un miembro hace check-in después de la hora de inicio.",
            icon: "clock.badge.exclamationmark",
            validScopes: ["resource", "series"],
            validResourceTypes: ["event"],
            sortOrder: 10
        ),
        RuleShape(
            id: "rsvpChangedSameDay",
            kind: .trigger,
            labelES: "Cuando alguien cancela el mismo día",
            summaryES: "Se dispara cuando un miembro cambia su RSVP a 'no voy' el día del evento.",
            icon: "person.crop.circle.badge.xmark",
            validScopes: ["resource", "series"],
            validResourceTypes: ["event"],
            sortOrder: 20
        ),
        RuleShape(
            id: "eventClosed",
            kind: .trigger,
            labelES: "Al cerrar el evento",
            summaryES: "Se dispara cuando el host cierra el evento.",
            icon: "checkmark.seal",
            validScopes: ["resource", "series", "group"],
            validResourceTypes: ["event"],
            sortOrder: 30
        ),
        RuleShape(
            id: "alwaysTrue",
            kind: .condition,
            labelES: "Sin condiciones extra",
            summaryES: "La regla aplica cada vez que se dispara el trigger.",
            sortOrder: 10
        ),
        RuleShape(
            id: "fine",
            kind: .consequence,
            labelES: "Cobrar una multa",
            icon: "banknote",
            configFields: [
                RuleShapeField(
                    key: "amount",
                    kind: .currency,
                    labelES: "Monto en MXN",
                    placeholder: "200",
                    defaultValue: .int(200),
                    min: 1,
                    max: 1_000_000
                )
            ],
            sortOrder: 10
        )
    ])
}
