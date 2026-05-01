import Foundation

/// Draft of a rule shown in the founder onboarding step 4. Mutable as the
/// user toggles enable/disable and edits the amount.
struct RuleDraft: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let code: String                  // matches Supabase rules.code: late, no_rsvp, etc.
    var title: String
    var description: String
    var amountMXN: Int                // editable inline
    var enabled: Bool
    let trigger: RuleTriggerSpec      // immutable per code

    init(
        id: UUID = UUID(),
        code: String,
        title: String,
        description: String,
        amountMXN: Int,
        enabled: Bool,
        trigger: RuleTriggerSpec
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.description = description
        self.amountMXN = amountMXN
        self.enabled = enabled
        self.trigger = trigger
    }
}

/// Mirror of the existing rule engine's trigger jsonb shape.
struct RuleTriggerSpec: Codable, Sendable, Hashable {
    let type: String
    var params: [String: AnyCodable]

    static let lateArrival = RuleTriggerSpec(
        type: "late_arrival",
        params: ["per_30min_increment": AnyCodable(50)]
    )

    static let noRSVP = RuleTriggerSpec(
        type: "no_rsvp_by_deadline",
        params: ["deadline_offset_hours": AnyCodable(-4)]
    )

    static let cancelSameDay = RuleTriggerSpec(
        type: "cancel_same_day",
        params: [:]
    )

    static let noShow = RuleTriggerSpec(
        type: "no_show",
        params: [:]
    )

    static let hostNoMenu = RuleTriggerSpec(
        type: "host_no_menu_24h",
        params: [:]
    )
}

/// Default 5 rules for paste 4. 4 enabled + 1 disabled.
extension RuleDraft {
    static let defaults: [RuleDraft] = [
        RuleDraft(
            code: "late",
            title: "Llegar tarde",
            description: "$200 base + $50 por cada 30 min después.",
            amountMXN: 200,
            enabled: true,
            trigger: .lateArrival
        ),
        RuleDraft(
            code: "no_rsvp",
            title: "No confirmar antes del día anterior",
            description: "Si no confirmas asistencia antes de las 20:00 del día anterior.",
            amountMXN: 200,
            enabled: true,
            trigger: .noRSVP
        ),
        RuleDraft(
            code: "cancel_same_day",
            title: "Cancelar el mismo día",
            description: "Si cancelas tu asistencia el día del evento.",
            amountMXN: 200,
            enabled: true,
            trigger: .cancelSameDay
        ),
        RuleDraft(
            code: "no_show",
            title: "No-show",
            description: "Si confirmaste y no llegaste sin avisar.",
            amountMXN: 300,
            enabled: true,
            trigger: .noShow
        ),
        RuleDraft(
            code: "host_no_menu",
            title: "Anfitrión sin avisar el menú",
            description: "Si eres host y no avisas el menú con 24h de anticipación.",
            amountMXN: 200,
            enabled: false,
            trigger: .hostNoMenu
        )
    ]
}

/// Lightweight Codable container so we can stash arbitrary JSON in trigger
/// params without pulling a JSON library.
struct AnyCodable: Codable, Sendable, Hashable {
    let value: Sendable

    init(_ value: Sendable) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self)    { self.value = v; return }
        if let v = try? c.decode(Double.self) { self.value = v; return }
        if let v = try? c.decode(Bool.self)   { self.value = v; return }
        if let v = try? c.decode(String.self) { self.value = v; return }
        if c.decodeNil()                       { self.value = NSNull(); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported type")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Int:    try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool:   try c.encode(v)
        case let v as String: try c.encode(v)
        case is NSNull:       try c.encodeNil()
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "unsupported type")
            )
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (let l as Int, let r as Int):       return l == r
        case (let l as Double, let r as Double): return l == r
        case (let l as Bool, let r as Bool):     return l == r
        case (let l as String, let r as String): return l == r
        case (is NSNull, is NSNull):             return true
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch value {
        case let v as Int:    hasher.combine(0); hasher.combine(v)
        case let v as Double: hasher.combine(1); hasher.combine(v)
        case let v as Bool:   hasher.combine(2); hasher.combine(v)
        case let v as String: hasher.combine(3); hasher.combine(v)
        case is NSNull:       hasher.combine(4)
        default: break
        }
    }
}
