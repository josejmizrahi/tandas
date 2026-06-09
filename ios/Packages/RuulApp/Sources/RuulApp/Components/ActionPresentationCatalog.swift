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

        // ── Resource general / settings (R.5A.B.5a catalog) ────────────────
        "edit_resource":         .init(symbolName: "pencil",                       tint: .orange),
        "archive_resource":      .init(symbolName: "archivebox.fill",              tint: .red),
        "restore_resource":      .init(symbolName: "arrow.uturn.backward.circle",  tint: .orange),
        "view_activity":         .init(symbolName: "clock.arrow.circlepath",       tint: .secondary),
        "transfer_resource":     .init(symbolName: "arrow.left.arrow.right",       tint: .red),
        "request_transfer":      .init(symbolName: "paperplane.fill",              tint: .orange),
        "approve_transfer":      .init(symbolName: "checkmark.seal.fill",          tint: .orange),
        "transfer_ownership":    .init(symbolName: "person.2.crop.square.stack.fill", tint: .red),
        "transfer_custody":      .init(symbolName: "hand.raised.fill",             tint: .orange),
        "return_resource":       .init(symbolName: "arrow.uturn.left.circle",      tint: .orange),
        "report_issue":          .init(symbolName: "exclamationmark.bubble.fill",  tint: .red),

        // ── Resource documents (R.5A.B.5a) ─────────────────────────────────
        "link_document":         .init(symbolName: "link",                         tint: .secondary),
        "upload_document":       .init(symbolName: "arrow.up.doc.fill",            tint: .secondary),
        "upload_new_version":    .init(symbolName: "arrow.up.doc.on.clipboard",    tint: .secondary),
        "request_approval":      .init(symbolName: "hand.raised.fill",             tint: .secondary),
        "reject_document":       .init(symbolName: "xmark.seal",                   tint: .red),
        "sign_document":         .init(symbolName: "signature",                    tint: .secondary),
        "archive_document":      .init(symbolName: "archivebox.fill",              tint: .red),

        // ── Resource maintenance / condition / valuation ───────────────────
        "record_maintenance":    .init(symbolName: "wrench.and.screwdriver.fill",  tint: .orange),
        "update_condition":      .init(symbolName: "gauge.with.dots.needle.67percent", tint: .orange),
        "update_valuation":      .init(symbolName: "chart.line.uptrend.xyaxis",    tint: .green),
        "record_damage":         .init(symbolName: "exclamationmark.triangle.fill", tint: .red),

        // ── Resource rights (R.5A.B.5a) ────────────────────────────────────
        "revoke_right":          .init(symbolName: "key.slash",                    tint: .red),

        // ── Resource reservations (R.5A.B.5a) ──────────────────────────────
        "view_availability":     .init(symbolName: "calendar",                     tint: .orange),
        "create_reservation":    .init(symbolName: "calendar.badge.plus",          tint: .orange),
        "approve_reservation":   .init(symbolName: "checkmark.seal.fill",          tint: .orange),
        "reject_reservation":    .init(symbolName: "xmark.seal",                   tint: .red),
        "cancel_reservation":    .init(symbolName: "xmark.circle",                 tint: .red),
        "complete_reservation":  .init(symbolName: "flag.checkered",               tint: .orange),
        "join_waitlist":         .init(symbolName: "hourglass",                    tint: .orange),
        "resolve_reservation_conflict": .init(symbolName: "exclamationmark.triangle.fill", tint: .red),
        "block_time":            .init(symbolName: "lock.fill",                    tint: .orange),
        "unblock_time":          .init(symbolName: "lock.open.fill",               tint: .orange),

        // ── Resource money (R.5A.B.5a) ─────────────────────────────────────
        "record_payment":        .init(symbolName: "creditcard.fill",              tint: .green),
        "record_iou":            .init(symbolName: "banknote.fill",                tint: .green),
        "record_charge":         .init(symbolName: "minus.circle.fill",            tint: .green),
        "record_payout":         .init(symbolName: "arrow.up.right.circle.fill",   tint: .green),
        "finalize_settlement_batch": .init(symbolName: "checkmark.circle.fill",    tint: .green),
        "void_transaction":      .init(symbolName: "xmark.circle.fill",            tint: .red),
        "export_statement":      .init(symbolName: "square.and.arrow.up",          tint: .green),

        // ── Resource relations (R.5A.B.5a) ─────────────────────────────────
        "link_existing_resource": .init(symbolName: "link.circle",                 tint: .secondary),
        "unlink_resource":        .init(symbolName: "link.badge.minus",            tint: .red),

        // ── Resource real estate (R.5A.B.5a) ───────────────────────────────
        "record_property_expense": .init(symbolName: "dollarsign.circle.fill",     tint: .green),
        "record_insurance":        .init(symbolName: "shield.fill",                tint: .blue),
        "record_tax_payment":      .init(symbolName: "doc.text.fill",              tint: .green),
        "record_lease_income":     .init(symbolName: "arrow.down.circle.fill",     tint: .green),
        "create_lease":            .init(symbolName: "doc.badge.plus",             tint: .secondary),
        "terminate_lease":         .init(symbolName: "xmark.octagon.fill",         tint: .red),

        // ── Resource inventory (R.5A.B.5a) ─────────────────────────────────
        "adjust_stock":          .init(symbolName: "shippingbox.fill",             tint: .orange),
        "transfer_stock":        .init(symbolName: "arrow.left.arrow.right.circle.fill", tint: .orange),
        "consume_item":          .init(symbolName: "minus.circle.fill",            tint: .orange),
        "record_purchase":       .init(symbolName: "cart.fill",                    tint: .green),

        // ── Event extras (R.5A.B.5a, resource-emitted) ─────────────────────
        "invite_participant":    .init(symbolName: "person.badge.plus",            tint: .blue),
        "mark_no_show":          .init(symbolName: "person.crop.circle.badge.xmark", tint: .red),
        "change_host":           .init(symbolName: "person.2.fill",                tint: .orange),
        "preview_next_host":     .init(symbolName: "eye.fill",                     tint: .secondary),
        "set_next_host":         .init(symbolName: "person.crop.circle.badge.checkmark", tint: .orange),
        "cancel_event":          .init(symbolName: "xmark.circle",                 tint: .red),
        "reopen_event":          .init(symbolName: "arrow.uturn.left.circle",      tint: .orange),
        "record_event_expense":  .init(symbolName: "dollarsign.circle.fill",       tint: .green),

        // ── Obligation extras (R.5A.B.5a, resource-emitted) ────────────────
        "accept_obligation":     .init(symbolName: "checkmark.circle.fill",        tint: .green),
        "complete_obligation":   .init(symbolName: "checkmark.circle.fill",        tint: .green),
        "dispute_obligation":    .init(symbolName: "exclamationmark.bubble.fill",  tint: .red),
        "forgive_obligation":    .init(symbolName: "heart.fill",                   tint: .pink),
        "extend_due_date":       .init(symbolName: "calendar.badge.clock",         tint: .orange),
        "convert_to_settlement": .init(symbolName: "arrow.right.circle.fill",      tint: .green),
        "cancel_obligation":     .init(symbolName: "xmark.circle",                 tint: .red),

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
