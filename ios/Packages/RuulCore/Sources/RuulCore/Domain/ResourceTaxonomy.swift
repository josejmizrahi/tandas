import Foundation

/// R.5A.B.0 — Una class de recurso (top-level taxonomy de Ruul).
/// 17 classes seedeadas: real_estate, vehicle, financial, document, event, etc.
public struct ResourceClass: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let classKey: String
    public let displayName: String
    public let description: String?
    public let icon: String?

    public var id: String { classKey }

    enum CodingKeys: String, CodingKey {
        case classKey = "class_key"
        case displayName = "display_name"
        case description
        case icon
    }

    public init(classKey: String, displayName: String, description: String? = nil, icon: String? = nil) {
        self.classKey = classKey
        self.displayName = displayName
        self.description = description
        self.icon = icon
    }
}

/// R.5A.B.0 — Un subtype de recurso. 42 subtypes seedeados + actualizable.
/// Founder firma 2026-06-07: las pantallas que crean recursos DEBEN elegir
/// subtype explícito (no resource_type legacy).
///
/// R.12.A — `fields` decodifica `metadata.fields[]` (FormFieldSpec array)
/// que define los campos específicos del subtype (placa/VIN para vehicle,
/// dirección/recámaras para real_estate, etc.). El iOS form engine los
/// renderea dinámicamente en Create/Edit.
public struct ResourceSubtype: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let subtypeKey: String
    public let classKey: String
    public let displayName: String
    public let description: String?
    public let fields: [FormFieldSpec]
    /// R.RES.POLICY.A — declara cómo se reserva este subtype (granularidad
    /// temporal, ventana de adelanto, aprobación). nil → recurso no es
    /// reservable o no se ha seedeado todavía. RequestReservationView
    /// adapta UI: día (casa) vs hora (vehículo) vs slot/none.
    public let reservationPolicy: ReservationPolicy?
    /// D.CATALOG.A — document_type keys priorizados al attach un documento
    /// a un resource de este subtype. AttachDocumentView muestra estos
    /// primero en la Section "Recomendados". Vacío para subtypes sin seed.
    public let recommendedDocumentTypes: [String]

    public var id: String { subtypeKey }

    enum CodingKeys: String, CodingKey {
        case subtypeKey = "subtype_key"
        case classKey = "class_key"
        case displayName = "display_name"
        case description
        case metadata
    }

    private struct MetadataWire: Decodable {
        let fields: [FormFieldSpec]?
        let reservationPolicy: ReservationPolicy?
        let recommendedDocumentTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case fields
            case reservationPolicy = "reservation_policy"
            case recommendedDocumentTypes = "recommended_document_types"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.subtypeKey = try c.decode(String.self, forKey: .subtypeKey)
        self.classKey = try c.decode(String.self, forKey: .classKey)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        let metadata = try c.decodeIfPresent(MetadataWire.self, forKey: .metadata)
        self.fields = metadata?.fields ?? []
        self.reservationPolicy = metadata?.reservationPolicy
        self.recommendedDocumentTypes = metadata?.recommendedDocumentTypes ?? []
    }

    public init(
        subtypeKey: String,
        classKey: String,
        displayName: String,
        description: String? = nil,
        fields: [FormFieldSpec] = [],
        reservationPolicy: ReservationPolicy? = nil,
        recommendedDocumentTypes: [String] = []
    ) {
        self.subtypeKey = subtypeKey
        self.classKey = classKey
        self.displayName = displayName
        self.description = description
        self.fields = fields
        self.reservationPolicy = reservationPolicy
        self.recommendedDocumentTypes = recommendedDocumentTypes
    }
}

/// R.RES.POLICY.A — política de reservaciones por subtype. Seedeado en
/// `resource_subtypes.metadata.reservation_policy`.
public struct ReservationPolicy: Codable, Sendable, Equatable, Hashable {
    /// Cómo se mide la unidad de reserva.
    /// - `day`: check-in / check-out por fechas (casa, departamento).
    /// - `hour`: slots horarios (vehículo, sala, equipo).
    /// - `event_slot`: la reserva se ata a un calendar_event (palco).
    /// - `none`: el subtype no es reservable (terreno, etc.).
    public let granularity: Granularity
    public let minDurationUnits: Int
    public let maxDurationUnits: Int?
    public let advanceWindowDays: Int?
    public let requiresApproval: Bool

    public enum Granularity: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case day, hour, eventSlot = "event_slot", none

        public var label: String {
            switch self {
            case .day:       return "Por días"
            case .hour:      return "Por horas"
            case .eventSlot: return "Por evento"
            case .none:      return "No reservable"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case granularity
        case minDurationUnits = "min_duration_units"
        case maxDurationUnits = "max_duration_units"
        case advanceWindowDays = "advance_window_days"
        case requiresApproval = "requires_approval"
    }

    public init(
        granularity: Granularity,
        minDurationUnits: Int = 1,
        maxDurationUnits: Int? = nil,
        advanceWindowDays: Int? = nil,
        requiresApproval: Bool = false
    ) {
        self.granularity = granularity
        self.minDurationUnits = minDurationUnits
        self.maxDurationUnits = maxDurationUnits
        self.advanceWindowDays = advanceWindowDays
        self.requiresApproval = requiresApproval
    }

    /// Una unidad de duración en segundos. Para `event_slot`/`none` retorna 0.
    public var unitSeconds: TimeInterval {
        switch granularity {
        case .day:       return 86_400
        case .hour:      return 3_600
        case .eventSlot, .none: return 0
        }
    }

    /// `true` si el subtype permite reservar (vista RequestReservationView).
    public var isReservable: Bool {
        granularity != .none
    }

    /// R.RES.POLICY.D — decode desde un `JSONValue` (raíz `resources.metadata`
    /// .reservation_policy_override). Tolera campos faltantes con defaults
    /// seguros. Devuelve nil si no hay granularity válida.
    public static func from(jsonValue value: JSONValue) -> ReservationPolicy? {
        guard case .object(let dict) = value else { return nil }
        guard case .string(let granRaw) = dict["granularity"] ?? .null,
              let granularity = Granularity(rawValue: granRaw) else {
            return nil
        }
        let minUnits: Int = {
            if case .number(let n) = dict["min_duration_units"] ?? .null { return Int(n) }
            return 1
        }()
        let maxUnits: Int? = {
            if case .number(let n) = dict["max_duration_units"] ?? .null { return Int(n) }
            return nil
        }()
        let advanceDays: Int? = {
            if case .number(let n) = dict["advance_window_days"] ?? .null { return Int(n) }
            return nil
        }()
        let requiresApproval: Bool = {
            if case .bool(let b) = dict["requires_approval"] ?? .null { return b }
            return false
        }()
        return ReservationPolicy(
            granularity: granularity,
            minDurationUnits: minUnits,
            maxDurationUnits: maxUnits,
            advanceWindowDays: advanceDays,
            requiresApproval: requiresApproval
        )
    }

    /// R.RES.POLICY.D — serializa el policy a `JSONValue.object` con el shape
    /// del backend (snake_case). Usado al guardar el override via updateResource.
    public func toJSONValue() -> JSONValue {
        var dict: [String: JSONValue] = [
            "granularity": .string(granularity.rawValue),
            "min_duration_units": .number(Double(minDurationUnits)),
            "requires_approval": .bool(requiresApproval)
        ]
        if let max = maxDurationUnits {
            dict["max_duration_units"] = .number(Double(max))
        } else {
            dict["max_duration_units"] = .null
        }
        if let days = advanceWindowDays {
            dict["advance_window_days"] = .number(Double(days))
        } else {
            dict["advance_window_days"] = .null
        }
        return .object(dict)
    }
}
