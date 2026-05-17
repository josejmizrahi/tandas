import Foundation

/// Beta 1 Consolidation W2-C2 — translates raw `Error` objects (from
/// PostgREST, Supabase Auth, URLSession, etc.) into user-facing
/// Spanish-MX messages.
///
/// Background: 15+ iOS call sites used to assign `error.localizedDescription`
/// or interpolate it into user-facing copy. PostgREST returns English
/// codes like `PGRST116`; Supabase Auth returns `JWT expired`; URLError
/// produces system descriptions. Family beta users were getting opaque
/// debugging strings at the worst moments.
///
/// Usage:
///   ```swift
///   self.error = RuulErrorTranslator.userMessage(for: error)
///   // or, equivalently:
///   self.error = error.ruulUserMessage
///   ```
///
/// Catalog evolves: when a new error class shows up in the wild, add a
/// case here rather than letting it fall through to the generic copy.
public enum RuulErrorTranslator {
    /// Returns a Spanish-MX user-facing message for `error`. Never
    /// surfaces internal codes, English strings, or system descriptions.
    public static func userMessage(for error: Error) -> String {
        // URLError: hit before localizedDescription matching so we get
        // semantically correct copy (the system's localizedDescription is
        // sometimes localized to the OS language, which isn't always
        // Spanish in test/CI environments).
        if let urlError = error as? URLError {
            return urlMessage(for: urlError)
        }

        let raw = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let lower = raw.lowercased()

        // PostgREST-style codes — see https://postgrest.org/en/stable/errors.html
        if lower.contains("pgrst116") {
            return "No encontramos lo que buscas."
        }
        if lower.contains("pgrst301") {
            return "Tu sesión expiró. Vuelve a entrar."
        }

        // Supabase Auth / GoTrue
        if lower.contains("jwt expired") || lower.contains("jwt is expired") {
            return "Tu sesión expiró. Vuelve a entrar."
        }
        if lower.contains("invalid token") || lower.contains("invalid jwt") {
            return "Tu sesión ya no es válida. Vuelve a entrar."
        }
        if lower.contains("invalid login credentials") || lower.contains("invalid otp") {
            return "Código incorrecto. Inténtalo de nuevo."
        }
        if lower.contains("rate limit") || lower.contains("too many requests")
            || lower.contains("429") || lower.contains("for security purposes")
            || lower.contains("only request this after") {
            // Supabase Auth devuelve "For security purposes, you can only
            // request this after X seconds" en 429 sin la palabra "rate"
            // ni el código 429 explícito en localizedDescription. Si el
            // segundo number aparece, lo respetamos al pie de la letra.
            if let seconds = Self.extractRateLimitSeconds(from: lower), seconds > 0 {
                return "Espera \(seconds) segundo\(seconds == 1 ? "" : "s") antes de pedir otro código."
            }
            return "Demasiados intentos. Espera un momento e inténtalo otra vez."
        }

        // Network-y strings that didn't come through URLError
        if lower.contains("network connection") || lower.contains("offline") {
            return "Sin conexión. Revisa tu internet."
        }

        // Last-resort generic — never surfaces the raw error.
        return "Algo salió mal. Inténtalo de nuevo."
    }

    /// Stable analytics-friendly bucket for `error`. Never user-facing —
    /// emitted alongside `error_shown` telemetry (Beta 1 W4 F-4.5) so we
    /// can aggregate "which error class is hitting beta users most" in
    /// the analytics pipeline. Bucket strings are intentionally coarse
    /// (no PII, no UUIDs, no free text from the error description).
    public static func errorCode(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .dataNotAllowed,
                 .internationalRoamingOff:           return "url_offline"
            case .timedOut:                          return "url_timeout"
            case .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:                   return "url_unreachable"
            case .userCancelledAuthentication,
                 .userAuthenticationRequired:       return "url_auth_required"
            default:                                 return "url_other"
            }
        }

        let raw = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let lower = raw.lowercased()

        if lower.contains("pgrst116")              { return "pgrst_not_found" }
        if lower.contains("pgrst301")              { return "pgrst_jwt_expired" }
        if lower.contains("jwt expired") || lower.contains("jwt is expired") {
            return "jwt_expired"
        }
        if lower.contains("invalid token") || lower.contains("invalid jwt") {
            return "jwt_invalid"
        }
        if lower.contains("invalid login credentials") || lower.contains("invalid otp") {
            return "otp_invalid"
        }
        if lower.contains("rate limit") || lower.contains("too many requests")
            || lower.contains("429") || lower.contains("for security purposes") {
            return "rate_limited"
        }
        if lower.contains("network connection") || lower.contains("offline") {
            return "network_offline"
        }
        return "generic"
    }

    /// Parse "after N seconds" / "after N second" del rate-limit message
    /// que devuelve Supabase Auth. Defensive: si no encuentra patrón
    /// devuelve nil y el caller fallback al copy genérico.
    private static func extractRateLimitSeconds(from message: String) -> Int? {
        let pattern = #"after\s+(\d+)\s+second"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: range),
              match.numberOfRanges >= 2,
              let digitRange = Range(match.range(at: 1), in: message),
              let value = Int(message[digitRange]) else { return nil }
        return value
    }

    private static func urlMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff:
            return "Sin conexión. Revisa tu internet."
        case .timedOut:
            return "La conexión tardó demasiado. Inténtalo de nuevo."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "No pudimos conectarnos al servidor. Inténtalo en un momento."
        case .userCancelledAuthentication, .userAuthenticationRequired:
            return "Necesitas volver a iniciar sesión."
        default:
            return "Algo salió mal con la conexión. Inténtalo de nuevo."
        }
    }
}

public extension Error {
    /// Spanish-MX user-facing message. Equivalent to
    /// `RuulErrorTranslator.userMessage(for: self)`.
    var ruulUserMessage: String {
        RuulErrorTranslator.userMessage(for: self)
    }
}
