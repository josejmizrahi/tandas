import Foundation
import Supabase

/// Traduce errores de supabase-swift (PostgrestError, URLError, decoding) a
/// `RuulError`. Los mensajes que reconoce son los `raise exception` de las
/// migrations MVP2 (`mvp2_*`, `r2*`).
public enum RPCErrorMapper {
    public static func map(_ error: any Error) -> RuulError {
        if let ruul = error as? RuulError { return ruul }
        if let pg = error as? PostgrestError {
            return .backend(parse(message: pg.message, code: pg.code))
        }
        if error is DecodingError {
            return .decoding(message: String(describing: error))
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return .network(message: (error as NSError).localizedDescription)
        }
        if error is CancellationError { return .cancelled }
        return .unexpected(message: (error as NSError).localizedDescription)
    }

    /// Parser de los mensajes del contrato MVP2. Visible para tests.
    static func parse(message raw: String, code: String?) -> BackendError {
        let s = raw.lowercased()

        if s.contains("unauthenticated") {
            return .unauthenticated
        }
        if code == "23P01" || s.contains("conflicting key value violates exclusion constraint") {
            return .reservationOverlap
        }
        if s.contains("not a member of context") || s.contains("not an active member of context") {
            return .notAMember
        }
        if s.contains("missing permission") {
            return .missingPermission(key: lastWord(of: raw))
        }
        if s.contains("not authorized") || s.contains("requires money.record_for_others")
            || code == "42501" {
            return .missingPermission(key: nil)
        }
        if s.contains("invite") && (s.contains("not found") || s.contains("expired")
            || s.contains("exhausted") || s.contains("revoked") || s.contains("invalid")) {
            return .invalidInvite(message: raw)
        }
        if code == "0A000" || s.contains("not_implemented") || s.contains("not implemented")
            || s.contains("action_not_wired") {
            return .notImplemented(actionKey: extractNotImplementedActionKey(from: raw))
        }
        if code == "22023" || s.contains("must be positive") || s.contains("is required")
            || s.contains("invalid") || s.contains("must sum to") || s.contains("duplicate") {
            return .validation(message: raw)
        }
        return .unknown(message: raw)
    }

    private static func lastWord(of raw: String) -> String? {
        raw.split(separator: " ").last.map(String.init)
    }

    /// Best-effort para sacar `action_key` de mensajes como
    /// `"action 'record_contribution' not_implemented"` o
    /// `"action_not_wired: record_contribution"`. Devuelve `nil` si no es claro.
    private static func extractNotImplementedActionKey(from raw: String) -> String? {
        if let quoted = raw.range(of: #"'([a-zA-Z_][a-zA-Z0-9_]*)'"#, options: .regularExpression) {
            let inside = raw[quoted].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if !inside.isEmpty { return inside }
        }
        if let colon = raw.range(of: ":") {
            let tail = raw[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            let token = tail.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).first.map(String.init)
            if let token, !token.isEmpty { return token }
        }
        return nil
    }
}
