import Foundation
import OSLog

@Observable @MainActor
final class InvitedOnboardingCoordinator {
    private(set) var currentStep: InvitedStep = .welcome
    private(set) var preview: InvitePreview?
    var displayName: String = ""
    var avatarLocalURL: URL?
    var phoneE164: String = ""
    private(set) var otpAttempts: Int = 0
    private(set) var otpChannel: OTPChannel = .whatsapp
    private(set) var error: OnboardingError?
    private(set) var isLoading: Bool = false

    let inviteCode: String
    private let groupRepo: any GroupsRepository
    private let inviteRepo: any InviteRepository
    private let otp: any OTPService
    private let analytics: any AnalyticsService
    private let progress: OnboardingProgressManager
    private let sessionId: UUID = UUID()
    private let startedAt: Date = .now
    private var stepEnteredAt: Date = .now
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "invited.onboarding")
    private var progressEntity: OnboardingProgress?
    private var matchingInviteId: UUID?

    init(
        inviteCode: String,
        groupRepo: any GroupsRepository,
        inviteRepo: any InviteRepository,
        otp: any OTPService,
        analytics: any AnalyticsService,
        progress: OnboardingProgressManager
    ) {
        self.inviteCode = inviteCode
        self.groupRepo = groupRepo
        self.inviteRepo = inviteRepo
        self.otp = otp
        self.analytics = analytics
        self.progress = progress
    }

    func start() async {
        let entity = OnboardingProgress(flowType: .invited, inviteCode: inviteCode)
        try? progress.save(entity)
        progressEntity = entity
        await analytics.track(.onboardingStarted(flowType: .invited))
        await loadPreview()
    }

    func restore(from entity: OnboardingProgress) async {
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

    // MARK: - Transitions

    func acceptInvitation() async {
        await complete(step: .welcome)
        try? await transition(to: .identity)
    }

    func declineInvitation() async {
        // No-op besides analytics. The view dismisses.
        await analytics.track(.stepSkipped(flowType: .invited, stepID: InvitedStep.welcome.rawValue))
    }

    func advanceFromIdentity() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await complete(step: .identity)
        try? await transition(to: .phoneVerify)
    }

    func advanceFromPhoneVerify() async {
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

    func submitOTP(code: String) async {
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

    func resetOTPAttempts() {
        otpAttempts = 0
        error = nil
    }

    func finishOnboarding() async {
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
