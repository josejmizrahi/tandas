import Foundation

// MARK: - R.5A.F.2 — Resource Action Form Schema (runtime form dialect)
//
// Dialect canónico del backend (R.5A.B.5b):
// {
//   "fields": [
//     { "key": "amount", "label": "Monto", "type": "currency", "required": true,
//       "options": ["MXN","USD","EUR"], "multiple": false }
//   ],
//   "submit_label": "Registrar gasto"
// }

public enum FormFieldType: String, Codable, Sendable, Equatable {
    case text
    case multiline
    case number
    case currency
    case date
    case datetime
    case boolean
    case picker
    case actorRef = "actor_ref"
    case resourceRef = "resource_ref"
    case fileUrl = "file_url"

    /// Default valor para inicializar el binding cuando la field no tiene valor todavía.
    public var defaultEmpty: JSONValue {
        switch self {
        case .text, .multiline, .actorRef, .resourceRef, .fileUrl, .picker:
            return .string("")
        case .number, .currency:
            return .number(0)
        case .boolean:
            return .bool(false)
        case .date, .datetime:
            return .null
        }
    }
}

public struct FormFieldSpec: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let key: String
    public let label: String
    public let type: FormFieldType
    public let required: Bool
    public let options: [String]
    public let multiple: Bool
    public let placeholder: String?
    public let helpText: String?

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case type
        case required
        case options
        case multiple
        case placeholder
        case helpText = "help_text"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? c.decode(String.self, forKey: .key)
        self.type = try c.decodeIfPresent(FormFieldType.self, forKey: .type) ?? .text
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        self.options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        self.multiple = try c.decodeIfPresent(Bool.self, forKey: .multiple) ?? false
        self.placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        self.helpText = try c.decodeIfPresent(String.self, forKey: .helpText)
    }

    public init(
        key: String,
        label: String,
        type: FormFieldType,
        required: Bool = false,
        options: [String] = [],
        multiple: Bool = false,
        placeholder: String? = nil,
        helpText: String? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.required = required
        self.options = options
        self.multiple = multiple
        self.placeholder = placeholder
        self.helpText = helpText
    }

    public var id: String { key }
}

public struct FormSchema: Sendable, Equatable {
    public let fields: [FormFieldSpec]
    public let submitLabel: String?

    public init(fields: [FormFieldSpec] = [], submitLabel: String? = nil) {
        self.fields = fields
        self.submitLabel = submitLabel
    }

    /// Decode desde el `form_schema` JSONValue del descriptor (B.5b).
    public init(from jsonSchema: JSONValue) {
        let data: Data
        do {
            data = try JSONEncoder().encode(jsonSchema)
        } catch {
            self.fields = []
            self.submitLabel = nil
            return
        }
        struct Wire: Decodable {
            let fields: [FormFieldSpec]?
            let submit_label: String?
        }
        let wire = try? JSONDecoder().decode(Wire.self, from: data)
        self.fields = wire?.fields ?? []
        self.submitLabel = wire?.submit_label
    }

    public var isEmpty: Bool { fields.isEmpty }
}
