import Testing
import Foundation
@testable import RuulFeatures

/// Beta 1 Consolidation — W1-4 regression coverage.
///
/// Bug: a brand-new device (`!hasOnboarded && session == nil`) landed on
/// `SignInView` whose header read "Bienvenido de vuelta" / "Inicia sesión
/// para volver a tus grupos." A first-time user would read that and
/// abandon, thinking they're on the wrong screen.
///
/// Fix: `SignInMode` carries the context (.firstTime vs .returning) from
/// AuthGate down to the view. The header copy + the "¿No tienes cuenta?"
/// fallback link are mode-aware. AuthGate maps `!hasOnboarded` →
/// `.firstTime`, anything else → `.returning`.
@Suite("SignInMode copy + affordances")
struct SignInModeCopyTests {
    @Test("first-time start header is welcome copy, not 'de vuelta'")
    func firstTimeStartHeader() {
        let mode = SignInMode.firstTime
        let headline = mode.startHeadline
        let subtitle = mode.startSubtitle
        #expect(headline == "Bienvenido a Ruul")
        #expect(subtitle == "Crea tu grupo o únete a uno con tu teléfono o Apple ID.")
    }

    @Test("returning start header keeps the original 'de vuelta' copy")
    func returningStartHeader() {
        let mode = SignInMode.returning
        #expect(mode.startHeadline == "Bienvenido de vuelta")
        #expect(mode.startSubtitle == "Inicia sesión para volver a tus grupos.")
    }

    @Test("first-time mode hides the 'Crear nueva' fallback link")
    func firstTimeHidesCreateAccountLink() {
        #expect(SignInMode.firstTime.showsCreateAccountLink == false)
    }

    @Test("returning mode keeps the 'Crear nueva' fallback link")
    func returningShowsCreateAccountLink() {
        #expect(SignInMode.returning.showsCreateAccountLink == true)
    }
}
