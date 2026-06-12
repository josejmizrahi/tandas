import Foundation

/// R.4B — Plantilla de decisión (`decision_templates_catalog`, lectura PostgREST
/// con RLS `select` a `authenticated`). El backend hereda `default_voting_model`
/// y despacha el efecto al ejecutar (`execute_decision`) según `execution_kind`.
///
/// Sólo 4 `execution_kind` tienen dispatch real hoy (`noop`, `archive_resource`,
/// `archive_rule`, `grant_resource_right`): esas plantillas son ejecutables con
/// un form de payload derivado de `payloadSchema`. El resto (los que `execute_decision`
/// rechaza con `0A000`) se presentan como `coming_soon` ("Próximamente"). El template
/// `reservation_award` tiene su propio entrypoint (conflicto de reservación → F.9).
public struct DecisionTemplate: Decodable, Sendable, Equatable, Identifiable {
    public let templateKey: String
    public let decisionType: String
    public let displayName: String
    public let description: String?
    public let defaultVotingModel: String
    public let defaultQuorum: Double?
    public let defaultApprovalThreshold: Double?
    public let payloadSchema: DecisionTemplatePayloadSchema
    public let executionKind: String

    public var id: String { templateKey }

    enum CodingKeys: String, CodingKey {
        case templateKey = "template_key"
        case decisionType = "decision_type"
        case displayName = "display_name"
        case description
        case defaultVotingModel = "default_voting_model"
        case defaultQuorum = "default_quorum"
        case defaultApprovalThreshold = "default_approval_threshold"
        case payloadSchema = "payload_schema"
        case executionKind = "execution_kind"
    }

    public init(
        templateKey: String,
        decisionType: String,
        displayName: String,
        description: String? = nil,
        defaultVotingModel: String = "yes_no_abstain",
        defaultQuorum: Double? = nil,
        defaultApprovalThreshold: Double? = nil,
        payloadSchema: DecisionTemplatePayloadSchema = .empty,
        executionKind: String
    ) {
        self.templateKey = templateKey
        self.decisionType = decisionType
        self.displayName = displayName
        self.description = description
        self.defaultVotingModel = defaultVotingModel
        self.defaultQuorum = defaultQuorum
        self.defaultApprovalThreshold = defaultApprovalThreshold
        self.payloadSchema = payloadSchema
        self.executionKind = executionKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.templateKey = try c.decode(String.self, forKey: .templateKey)
        self.decisionType = try c.decode(String.self, forKey: .decisionType)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.defaultVotingModel = try c.decodeIfPresent(String.self, forKey: .defaultVotingModel) ?? "yes_no_abstain"
        self.defaultQuorum = try c.decodeIfPresent(Double.self, forKey: .defaultQuorum)
        self.defaultApprovalThreshold = try c.decodeIfPresent(Double.self, forKey: .defaultApprovalThreshold)
        self.payloadSchema = try c.decodeIfPresent(DecisionTemplatePayloadSchema.self, forKey: .payloadSchema) ?? .empty
        self.executionKind = try c.decode(String.self, forKey: .executionKind)
    }

    /// `execution_kind` que `execute_decision` despacha hoy. El resto rebota con `0A000`.
    public static let executableKinds: Set<String> = [
        "noop", "archive_resource", "archive_rule", "grant_resource_right"
    ]

    public var voting: VotingModel { VotingModel(rawValue: defaultVotingModel) ?? .yesNoAbstain }

    /// La plantilla se puede crear Y ejecutar end-to-end (form de payload).
    public var isExecutable: Bool { Self.executableKinds.contains(executionKind) }

    /// `reservation_award` — disputa de reservación; entra por F.9, no por el picker.
    public var isReservationAward: Bool { executionKind == "reservation_award" }

    /// Deferred (`0A000`): se ofrece como `coming_soon` "Próximamente".
    public var isComingSoon: Bool { !isExecutable && !isReservationAward }

    /// `noop` no lleva form — la decisión sólo registra el resultado.
    public var hasPayloadForm: Bool { isExecutable && executionKind != "noop" && !payloadSchema.fields.isEmpty }

    /// Nombres de los campos `required` ausentes (o vacíos) en `values`.
    /// `values` sólo debe contener entradas no vacías (el form omite las vacías).
    public func missingRequiredFields(in values: [String: JSONValue]) -> [String] {
        payloadSchema.fields
            .filter { $0.required && values[$0.name] == nil }
            .map(\.name)
    }
}

/// Esquema del payload de una plantilla (`payload_schema` jsonb). Puede venir
/// vacío (`{}`, p.ej. `noop`) o con `fields` + `notes`.
public struct DecisionTemplatePayloadSchema: Decodable, Sendable, Equatable {
    public let fields: [Field]
    public let notes: String?

    public static let empty = DecisionTemplatePayloadSchema(fields: [], notes: nil)

    enum CodingKeys: String, CodingKey {
        case fields
        case notes
    }

    public init(fields: [Field], notes: String? = nil) {
        self.fields = fields
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? []
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    /// Un campo del payload. `type` ∈ uuid | numeric | text | array | jsonb | bool.
    public struct Field: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let type: String
        public let required: Bool

        public var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, type, required
        }

        public init(name: String, type: String, required: Bool = false) {
            self.name = name
            self.type = type
            self.required = required
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.type = try c.decode(String.self, forKey: .type)
            self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        }

        public var kind: Kind { Kind(rawValue: type) ?? .text }

        public enum Kind: String, Sendable {
            case uuid, numeric, text, array, jsonb, bool
        }
    }
}
