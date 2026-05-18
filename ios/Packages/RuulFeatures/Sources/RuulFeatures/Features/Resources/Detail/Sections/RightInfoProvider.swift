import Foundation
import RuulCore
import RuulUI

/// Right-specific INFORMACIÓN rows. Extracted from
/// `UniversalResourceDetailView.typeSpecificRows` per ontology
/// constitution Rule 6. Registered with `ResourceInfoRegistry` at boot.
///
/// Affirmative-only rendering: default values (priority 0, exclusive
/// false, etc.) are hidden so the card stays scannable. Status row
/// only renders when state is `expired` or `revoked` (active is
/// implicit).
@MainActor
public enum RightInfoProvider {
    public static func rows(for ctx: ResourceDetailContext) -> [ResourceInfoRow] {
        var out: [ResourceInfoRow] = []

        // Titular: holder_user_id is auth.users.id; directory keyed by
        // userId works for the lookup.
        if let holderUid = uuidFromMeta(ctx, "holder_user_id"),
           let holder = ctx.memberDirectory[holderUid] {
            out.append(ResourceInfoRow(label: "Titular", value: holder.displayName))
        }
        // Delegado: when set, signals who can exercise today.
        if let delegateUid = uuidFromMeta(ctx, "delegate_user_id"),
           let delegate = ctx.memberDirectory[delegateUid] {
            out.append(ResourceInfoRow(label: "Delegado", value: delegate.displayName))
        }
        // Estado: only non-default states. `active` is implicit.
        switch ctx.resource.status {
        case "expired": out.append(ResourceInfoRow(label: "Estado", value: "Vencido"))
        case "revoked": out.append(ResourceInfoRow(label: "Estado", value: "Revocado"))
        default: break
        }
        // Suspension: separate from status. Pull `suspended_until` when
        // set; else just signal the suspended state.
        if let until = parseISOMeta(ctx, "suspended_until") {
            out.append(ResourceInfoRow(label: "Suspendido hasta", value: until.ruulShortDate))
        } else if ctx.resource.metadata["suspended_at"]?.stringValue != nil {
            out.append(ResourceInfoRow(label: "Estado", value: "Suspendido"))
        }
        // Priority: only when explicitly > 0.
        if let priority = ctx.resource.metadata["priority"]?.intValue, priority > 0 {
            out.append(ResourceInfoRow(label: "Prioridad", value: "\(priority)"))
        }
        // Affirmative flags only when true.
        if ctx.resource.metadata["exclusive"]?.boolValue == true {
            out.append(ResourceInfoRow(label: "Alcance", value: "Exclusivo"))
        }
        if ctx.resource.metadata["transferable"]?.boolValue == true {
            out.append(ResourceInfoRow(label: "Transferible", value: "Sí"))
        }
        if ctx.resource.metadata["delegable"]?.boolValue == true {
            out.append(ResourceInfoRow(label: "Delegable", value: "Sí"))
        }
        // Expiration: forward-looking only. The expire_due_rights cron
        // flips status to `expired` once the date lapses, so a future
        // date is the meaningful signal.
        if let expires = parseISOMeta(ctx, "expires_at"), expires > Date.now {
            out.append(ResourceInfoRow(label: "Vence", value: expires.ruulShortDate))
        }
        return out
    }

    private static func uuidFromMeta(_ ctx: ResourceDetailContext, _ key: String) -> UUID? {
        guard let raw = ctx.resource.metadata[key]?.stringValue, !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    private static func parseISOMeta(_ ctx: ResourceDetailContext, _ key: String) -> Date? {
        guard let raw = ctx.resource.metadata[key]?.stringValue, !raw.isEmpty else { return nil }
        if let date = isoFrac.date(from: raw) { return date }
        return isoPlain.date(from: raw)
    }

    private nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
