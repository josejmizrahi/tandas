import XCTest

@MainActor
final class HappyPathTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// DISABLED for Onboarding V1.
    ///
    /// The original happy-path script targeted the Phase 1 LoginView +
    /// EmptyGroupsView + NewGroupWizard flow. Onboarding V1 replaces all of
    /// those with the new founder coordinator flow (WelcomeView →
    /// FounderIdentityView → GroupIdentityView → ... → ConfirmationView).
    ///
    /// TODO: rewrite this UI test to drive the new flow:
    ///   1. Tap "Empezar" on WelcomeView
    ///   2. Type name → tap Continuar
    ///   3. Type group name + pick a cover → tap "Crear grupo"
    ///   4. Skip vocabulary → skip rules → skip invite
    ///   5. Type phone → mock OTP service auto-verifies
    ///   6. Land on ConfirmationView
    func testFullOnboardingThroughCreatingGroup() throws {
        try XCTSkipIf(true, "Pending rewrite for Onboarding V1 flow")
    }
}
