import Testing
import Foundation
@testable import RuulCore

/// Beta 1 Consolidation — W2-C2 regression coverage.
///
/// Bug: 15+ iOS call sites assigned `error.localizedDescription` (or
/// interpolated it into otherwise-friendly copy) when showing errors
/// to the user. PostgREST + Supabase Auth surface English / technical
/// strings ("PGRST116: ...", "JWT expired"); URLError surfaces raw
/// system descriptions. Mexican beta users got an opaque debugging
/// message at the worst possible moment.
///
/// Fix: `RuulErrorTranslator.userMessage(for:)` maps known patterns
/// to Spanish-MX copy and falls through to a generic "Algo salió mal."
/// for unknowns. Callers stop touching `.localizedDescription` directly.
@Suite("RuulErrorTranslator")
struct RuulErrorTranslatorTests {
    private struct DescribedError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Test("PGRST116 (no rows) → 'no encontramos'")
    func pgrst116NoRows() {
        let err = DescribedError(message: "PGRST116: searched for one row, but 0 rows were returned")
        let msg = RuulErrorTranslator.userMessage(for: err)
        #expect(msg.localizedCaseInsensitiveContains("no encontramos"))
        #expect(!msg.contains("PGRST"))
    }

    @Test("JWT expired → 'sesión expiró'")
    func jwtExpired() {
        let err = DescribedError(message: "JWT expired")
        let msg = RuulErrorTranslator.userMessage(for: err)
        #expect(msg.localizedCaseInsensitiveContains("sesión") ||
                msg.localizedCaseInsensitiveContains("sesion"))
        #expect(msg.localizedCaseInsensitiveContains("expir"))
        #expect(!msg.localizedCaseInsensitiveContains("jwt"))
    }

    @Test("URLError notConnectedToInternet → 'sin conexión'")
    func notConnectedToInternet() {
        let err = URLError(.notConnectedToInternet)
        let msg = RuulErrorTranslator.userMessage(for: err)
        #expect(msg.localizedCaseInsensitiveContains("conexión") ||
                msg.localizedCaseInsensitiveContains("conexion"))
    }

    @Test("URLError timedOut → 'tardó demasiado'")
    func timedOut() {
        let err = URLError(.timedOut)
        let msg = RuulErrorTranslator.userMessage(for: err)
        #expect(msg.localizedCaseInsensitiveContains("tardó") ||
                msg.localizedCaseInsensitiveContains("tardo"))
    }

    @Test("unknown errors fall through to a generic Spanish message")
    func genericFallback() {
        let err = DescribedError(message: "kaboom random server thing")
        let msg = RuulErrorTranslator.userMessage(for: err)
        #expect(msg.localizedCaseInsensitiveContains("salió") ||
                msg.localizedCaseInsensitiveContains("salio") ||
                msg.localizedCaseInsensitiveContains("intenta"))
        #expect(!msg.contains("kaboom"), "raw error must not leak")
    }

    @Test("Error.ruulUserMessage extension produces same output as direct call")
    func extensionParity() {
        let err = URLError(.notConnectedToInternet)
        #expect(err.ruulUserMessage == RuulErrorTranslator.userMessage(for: err))
    }
}
