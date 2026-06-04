import SwiftUI

/// F.2X — Presentación visual (SF Symbol + tint) para cada `action_key` canónico
/// emitido por el backend.
///
/// **Responsabilidad única:** traducir `action_key` → `(symbolName, tint)`.
/// El `label` lo manda backend en `AvailableAction.label` (es-MX) — el catálogo
/// NO lo sobrescribe.
///
/// **Hard no:** ningún branch por `resource_type / event_type / decision_type`.
/// Si aparece un `action_key` nuevo, se agrega una entrada aquí — la UI no se
/// modifica en ningún otro lugar.
public struct ActionPresentation: Sendable, Equatable {
    public let symbolName: String
    public let tint: Color

    public init(symbolName: String, tint: Color = .accentColor) {
        self.symbolName = symbolName
        self.tint = tint
    }
}

public enum ActionPresentationCatalog {

    /// Devuelve la presentación canónica para un `action_key`.
    /// Para keys desconocidos cae a un símbolo genérico para no romper la UI
    /// si el backend introduce uno nuevo antes de que iOS lo registre.
    public static func presentation(for actionKey: String) -> ActionPresentation {
        Self.table[actionKey] ?? ActionPresentation(symbolName: "ellipsis.circle", tint: .secondary)
    }

    // MARK: - Tabla
    // Colores per founder color doctrine:
    //   Resources/Calendar = .orange
    //   Decisions          = .purple
    //   Money              = .green
    //   Members            = .blue
    //   Rules              = .indigo
    //   Destructivo        = .red
    //   Neutral/Docs       = .secondary

    private static let table: [String: ActionPresentation] = [

        // ── Context-level (F.2X.0) ─────────────────────────────────────────
        "create_resource":      .init(symbolName: "shippingbox.fill",       tint: .orange),
        "create_event":         .init(symbolName: "calendar.badge.plus",    tint: .orange),
        "create_decision":      .init(symbolName: "checkmark.bubble.fill",  tint: .purple),
        "record_expense":       .init(symbolName: "dollarsign.circle.fill", tint: .green),
        "invite_member":        .init(symbolName: "person.badge.plus",      tint: .blue),
        "create_rule":          .init(symbolName: "scroll.fill",            tint: .indigo),
        "create_child_context": .init(symbolName: "rectangle.split.2x1.fill", tint: .blue),

        // ── Event-level (F.2X.0) ───────────────────────────────────────────
        "rsvp_event":           .init(symbolName: "hand.raised.fill",       tint: .orange),
        "check_in_participant": .init(symbolName: "checkmark.circle.fill",  tint: .orange),
        "cancel_participation": .init(symbolName: "xmark.circle",           tint: .red),
        "close_event":          .init(symbolName: "flag.checkered",         tint: .orange),
        "edit_event":           .init(symbolName: "pencil",                 tint: .orange),
        "attach_document":      .init(symbolName: "paperclip",              tint: .secondary),

        // ── Resource-level (R.2S.9 / R.2M.3) ────────────────────────────────
        "reserve_resource":     .init(symbolName: "calendar.badge.clock",   tint: .orange),
        "view_beneficiaries":   .init(symbolName: "gift.fill",              tint: .orange),
        "view_ownership":       .init(symbolName: "chart.pie.fill",         tint: .orange),
        "grant_right":          .init(symbolName: "key.fill",               tint: .blue),
        "update_resource":      .init(symbolName: "pencil",                 tint: .orange),

        // ── Decision-level (R.2S.9) ────────────────────────────────────────
        "vote":                 .init(symbolName: "hand.thumbsup.fill",     tint: .purple),
        "change_vote":          .init(symbolName: "arrow.triangle.2.circlepath", tint: .purple),
        "close_decision":       .init(symbolName: "lock.fill",              tint: .purple),
        "cancel_decision":      .init(symbolName: "xmark.circle",           tint: .red),
        "execute_decision":     .init(symbolName: "play.circle.fill",       tint: .purple),
        "edit_decision":        .init(symbolName: "pencil",                 tint: .purple),

        // ── Reservation-level (R.2S.9) ─────────────────────────────────────
        "approve":              .init(symbolName: "checkmark.seal.fill",    tint: .orange),
        "reject":               .init(symbolName: "xmark.seal",             tint: .red),
        "confirm":              .init(symbolName: "checkmark.circle.fill",  tint: .orange),
        "cancel":               .init(symbolName: "xmark.circle",           tint: .red),
        "resolve_conflict":     .init(symbolName: "exclamationmark.triangle.fill", tint: .red),

        // ── Obligation-level (R.2S.9) ──────────────────────────────────────
        "pay":                  .init(symbolName: "creditcard.fill",        tint: .green),
        "mark_completed":       .init(symbolName: "checkmark.circle.fill",  tint: .green),
        "dispute":              .init(symbolName: "exclamationmark.bubble.fill", tint: .red),
        "forgive":              .init(symbolName: "heart.fill",             tint: .pink),
        "edit_obligation":      .init(symbolName: "pencil",                 tint: .green),
    ]
}
