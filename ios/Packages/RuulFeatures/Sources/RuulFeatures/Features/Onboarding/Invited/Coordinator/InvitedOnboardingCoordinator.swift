import Foundation
import OSLog
import RuulCore
import RuulUI

@Observable @MainActor
public final class InvitedOnboardingCoordinator {
    public private(set) var currentStep: InvitedStep = .welcome
    public private(set) var preview: InvitePreview?
    public var displayName: String = ""
    public var avatarLocalURL: URL?
    public var phoneE164: String = ""
    public private(set) var otpAttempts: Int = 0
    public private(set) var otpChannel: OTPChannel = .whatsapp
    public private(set) var error: OnboardingError?
    public private(set) var isLoading: Bool = false

    /// `LoadPhase` derived from the invite preview lifecycle. Scalar
    /// (single `InvitePreview`), surfaced to `InviteWelcomeView` so it
    /// can render the standard loading/error/loaded primitives instead
    /// of an ad-hoc if/else chain. Onboarding-specific errors that need
    /// custom copy (e.g. `.inviteCodeInvalid`) translate into a
    /// `CoordinatorError` with the right title so the user still gets
    /// the "invitación ya no válida" message rather than a generic
    /// "algo salió mal".
    public var previewPhase: LoadPhase<InvitePreview> {
        if let err = error {
            let mapped = CoordinatorError(
                title: err.errorDescription ?? "Algo salió mal",
                message: nil,
                isRetryable: err.isRecoverable
            )
            return .failed(mapped, previous: preview)
        }
        if let preview {
            return isLoading ? .refreshing(preview) : .loaded(preview)
        }
        return isLoading ? .loading : .idle
    }

    public let inviteCode: String
    private let groupRepo: any GroupsRepository
    private let inviteRepo: any InviteRepository
    private let otp: any OTPService
    private let analytics: any AnalyticsService
    private let progress: any OnboardingProgressPersisting
    private let sessionId: UUID = UUID()
    private let startedAt: Date = .now
    private var stepEnteredAt: Date = .now
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "invited.onboarding")
    private var progressEntity: OnboardingProgress?
    private var matchingInviteId: UUID?

    public init(
        inviteCode: String,
        groupRepo: any GroupsRepository,
        inviteRepo: any InviteRepository,
        otp: any OTPService,
        analytics: any AnalyticsService,
        progress: any OnboardingProgressPersisting
    ) {
        self.inviteCode = inviteCode
        self.groupRepo = groupRepo
        self.inviteRepo = inviteRepo
        self.otp = otp
        self.analytics = analytics
        self.progress = progress
    }

    public func start() async {
        let entity = OnboardingProgress(flowType: .invited, inviteCode: inviteCode)
        try? progress.save(entity)
        progressEntity = entity
        await analytics.track(.onboardingStarted(flowType: .invited))
        await loadPreview()
    }

    public func restore(from entity: OnboardingProgress) async {
        progressEntity = entity
        if let step = entity.invitedStep {
            currentStep = step
        }
        if let name = entity.displayName { displayName = name }
        if let phone = entity.phoneE164 { phoneE164 = phone }
        await analytics.track(.stepStarted(flowType: .invited, stepID: currentStep.rawValue, stepIndex: currentStep.index))
        // Always re-fetch the preview on restore (it may have changed).
        await loadPreview()
    }

    private func loadPreview() async {
        isLoading = true
        defer { isLoading = false }
        do {
            preview = try await groupRepo.fetchPreview(byInviteCode: inviteCode)
            await trackStepStart(.welcome)
        } catch {
            self.error = .inviteCodeInvalid
        }
    }

    /// Beta 1 skip-by-default: the welcome screen for invited users shows
    /// the group preview ("Estás invitado a Cena de Los Cuates"). That's
    /// useful info — but if the preview already loaded the user can tap
    /// straight through. The view calls `acceptInvitation()` which is the
    /// equivalent transition. Welcome stays visible (it's the moment the
    /// user decides to accept) — only auto-skip happens via the founder
    /// flow where the welcome screen has no information value.

    // MARK: - Transitions

    public func acceptInvitation() async {
        await complete(step: .welcome)
        try? await transition(to: .identity)
    }

    public func declineInvitation() async {
        // No-op besides analytics. The view dismisses.
        await analytics.track(.stepSkipped(flowType: .invited, stepID: InvitedStep.welcome.rawValue))
    }

    public func advanceFromIdentity() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await complete(step: .identity)
        try? await transition(to: .phoneVerify)
    }

    public func advanceFromPhoneVerify() async {
        guard !phoneE164.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            otpChannel = try await otp.requestCode(phoneE164: phoneE164)
            await analytics.track(.otpRequested(channel: otpChannel.rawValue))
            await complete(step: .phoneVerify)
            try? await transition(to: .otp)
        } catch {
            self.error = .otpSendFailed(error.localizedDescription)
        }
    }

    public func submitOTP(code: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        otpAttempts += 1
        do {
            try await otp.verifyCode(phoneE164: phoneE164, code: code, channel: otpChannel)
            await analytics.track(.otpVerified(channel: otpChannel.rawValue, attempts: otpAttempts))
            OnboardingCompletion.mark()
            // Mark invite used (best effort — failure here is logged but doesn't stop the flow).
            if let inviteId = matchingInviteId {
                _ = try? await inviteRepo.markUsed(inviteId: inviteId)
            }
            await complete(step: .otp)
            try? await transition(to: .tour)
            await trackOnboardingCompleted()
        } catch {
            await analytics.track(.otpFailed(channel: otpChannel.rawValue, attempts: otpAttempts, reason: error.localizedDescription))
            if otpAttempts >= 3 {
                self.error = .otpTooManyAttempts
            } else {
                self.error = .otpVerifyFailed(reason: error.localizedDescription, attempts: otpAttempts)
            }
        }
    }

    public func resetOTPAttempts() {
        otpAttempts = 0
        error = nil
    }

    public func finishOnboarding() async {
        try? progress.clear()
        progressEntity = nil
    }

    // MARK: - Helpers

    private func transition(to step: InvitedStep) async throws {
        currentStep = step
        stepEnteredAt = .now
        await persist()
        await trackStepStart(step)
    }

    private func complete(step: InvitedStep) async {
        let elapsed = Int(Date().timeIntervalSince(stepEnteredAt) * 1000)
        await analytics.track(.stepCompleted(flowType: .invited, stepID: step.rawValue, timeOnStepMs: elapsed))
    }

    private func trackStepStart(_ step: InvitedStep) async {
        await analytics.track(.stepStarted(flowType: .invited, stepID: step.rawValue, stepIndex: step.index))
    }

    private func trackOnboardingCompleted() async {
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        await analytics.track(.memberJoinedViaInvite(timeFromInviteSentSeconds: nil))
        await analytics.track(.onboardingCompleted(flowType: .invited, totalTimeMs: elapsed))
    }

    private func persist() async {
        guard let entity = progressEntity else { return }
        entity.invitedStep = currentStep
        entity.displayName = displayName
        entity.phoneE164 = phoneE164.isEmpty ? nil : phoneE164
        try? progress.save(entity)
    }
}
