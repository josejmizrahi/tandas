import Foundation
import OSLog

@Observable @MainActor
final class FounderOnboardingCoordinator {
    private(set) var currentStep: FounderStep = .welcome
    var draft: GroupDraft = .empty
    var displayName: String = ""
    var avatarLocalURL: URL?
    var phoneE164: String = ""
    private(set) var otpAttempts: Int = 0
    private(set) var otpChannel: OTPChannel = .whatsapp
    var pendingInvites: [PendingInvite] = []
    private(set) var createdGroup: Group?
    private(set) var error: OnboardingError?
    private(set) var isLoading: Bool = false

    private let groupRepo: any GroupsRepository
    private let inviteRepo: any InviteRepository
    private let ruleRepo: any RuleRepository
    private let otp: any OTPService
    private let analytics: any AnalyticsService
    private let progress: OnboardingProgressManager
    private let sessionId: UUID = UUID()
    private let startedAt: Date = .now
    private var stepEnteredAt: Date = .now
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "founder.onboarding")
    private var progressEntity: OnboardingProgress?

    init(
        groupRepo: any GroupsRepository,
        inviteRepo: any InviteRepository,
        ruleRepo: any RuleRepository,
        otp: any OTPService,
        analytics: any AnalyticsService,
        progress: OnboardingProgressManager
    ) {
        self.groupRepo = groupRepo
        self.inviteRepo = inviteRepo
        self.ruleRepo = ruleRepo
        self.otp = otp
        self.analytics = analytics
        self.progress = progress
    }

    func start() async {
        let entity = OnboardingProgress(flowType: .founder)
        try? progress.save(entity)
        progressEntity = entity
        await analytics.track(.onboardingStarted(flowType: .founder))
        await trackStepStart(.welcome)
    }

    /// Restore from a previous in-progress entity. Reseats currentStep + draft.
    func restore(from entity: OnboardingProgress) async {
        progressEntity = entity
        if let step = entity.founderStep {
            currentStep = step
        }
        if let data = entity.draftJSON, let decoded = try? JSONDecoder().decode(GroupDraft.self, from: data) {
            draft = decoded
        }
        if let name = entity.displayName { displayName = name }
        if let phone = entity.phoneE164 { phoneE164 = phone }
        log.debug("restored at step \(self.currentStep.rawValue)")
        await analytics.track(.stepStarted(flowType: .founder, stepID: currentStep.rawValue, stepIndex: currentStep.index))
        stepEnteredAt = .now
    }

    // MARK: - Transitions

    func advanceFromWelcome() async {
        await complete(step: .welcome)
        try? await transition(to: .identity)
    }

    func advanceFromIdentity() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await complete(step: .identity)
        try? await transition(to: .templateSelect)
    }

    func skipIdentity() async {
        displayName = ""
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.identity.rawValue))
        try? await transition(to: .templateSelect)
    }

    /// Sprint 1b: TemplateSelectorView auto-advances 600ms after selection.
    /// Pure transition — `draft.template` is set by the view itself when the
    /// user taps a card; this just moves the flow forward.
    func advanceFromTemplateSelect() async {
        await complete(step: .templateSelect)
        try? await transition(to: .group)
    }

    func advanceFromGroupIdentity() async {
        guard draft.isReadyToCreate, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let group = try await groupRepo.createInitial(draft)
            createdGroup = group
            // Sprint 1b: seed the 5 default Platform rules for the chosen
            // template. Idempotent — safe to retry if the user re-enters
            // this step after a connectivity blip. Failure here is non-fatal:
            // the legacy rule step (.rules) still works; we just log so we
            // can surface in analytics later.
            if draft.template == DinnerRecurringTemplate.TemplateID.dinnerRecurring.rawValue {
                do {
                    _ = try await ruleRepo.seedDinnerTemplateRules(groupId: group.id)
                } catch {
                    log.warning("seedDinnerTemplateRules failed: \(error.localizedDescription)")
                }
            }
            await complete(step: .group)
            try? await transition(to: .vocabulary)
        } catch {
            self.error = .createGroupFailed(error.localizedDescription)
            await analytics.track(.stepFailed(flowType: .founder, stepID: FounderStep.group.rawValue, errorType: "create_group"))
        }
    }

    func advanceFromVocabulary() async {
        guard let group = createdGroup, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let patch = GroupConfigPatch(
            eventLabel: draft.resolvedVocabulary,
            frequencyType: draft.frequencyType,
            frequencyConfig: draft.frequencyConfig
        )
        do {
            createdGroup = try await groupRepo.updateConfig(groupId: group.id, patch: patch)
            await complete(step: .vocabulary)
            try? await transition(to: .rules)
        } catch {
            self.error = .updateGroupFailed(error.localizedDescription)
            await analytics.track(.stepFailed(flowType: .founder, stepID: FounderStep.vocabulary.rawValue, errorType: "update"))
        }
    }

    func skipVocabulary() async {
        draft.frequencyType = nil
        draft.frequencyConfig = .empty
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.vocabulary.rawValue))
        try? await transition(to: .rules)
    }

    func advanceFromRules() async {
        guard let group = createdGroup, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let enabledDrafts = draft.rules.filter(\.enabled)
        do {
            _ = try await ruleRepo.createInitialRules(groupId: group.id, drafts: enabledDrafts)
            let patch = GroupConfigPatch(
                finesEnabled: !enabledDrafts.isEmpty,
                rotationMode: draft.rotationMode
            )
            createdGroup = try await groupRepo.updateConfig(groupId: group.id, patch: patch)
            await complete(step: .rules)
            try? await transition(to: .invite)
        } catch {
            self.error = .createRulesFailed(error.localizedDescription)
            await analytics.track(.stepFailed(flowType: .founder, stepID: FounderStep.rules.rawValue, errorType: "create_rules"))
        }
    }

    func skipRules() async {
        draft.finesEnabled = false
        draft.rules = draft.rules.map {
            var copy = $0; copy.enabled = false; return copy
        }
        guard let group = createdGroup else { return }
        isLoading = true
        defer { isLoading = false }
        let patch = GroupConfigPatch(finesEnabled: false, rotationMode: draft.rotationMode)
        if let updated = try? await groupRepo.updateConfig(groupId: group.id, patch: patch) {
            createdGroup = updated
        }
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.rules.rawValue))
        try? await transition(to: .invite)
    }

    func advanceFromInvite() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let group = createdGroup else { return }
        for pending in pendingInvites where pending.sentAt == nil {
            do {
                _ = try await inviteRepo.createInvite(groupId: group.id, phoneE164: pending.phoneE164)
                if let idx = pendingInvites.firstIndex(where: { $0.id == pending.id }) {
                    pendingInvites[idx].sentAt = .now
                }
                await analytics.track(.inviteSent(method: "manual_phone"))
            } catch {
                log.warning("invite send failed: \(error.localizedDescription)")
            }
        }
        await complete(step: .invite)
        try? await transition(to: .phoneVerify)
    }

    func skipInvite() async {
        pendingInvites.removeAll()
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.invite.rawValue))
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
            await analytics.track(.stepFailed(flowType: .founder, stepID: FounderStep.phoneVerify.rawValue, errorType: "otp_send"))
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
            await complete(step: .otp)
            try? await transition(to: .confirm)
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

    /// Skip the phone+OTP path: the user authenticated with Apple via the
    /// SiwA button on PhoneVerifyView (Supabase upgrades the current anon
    /// session to a real user when signInWithIdToken is called). Mark phone
    /// + otp steps complete and transition straight to confirmation.
    func completeViaApple() async {
        await complete(step: .phoneVerify)
        await complete(step: .otp)
        try? await transition(to: .confirm)
        await trackOnboardingCompleted()
        await analytics.track(.otpVerified(channel: "apple", attempts: 0))
    }

    func finishOnboarding() async {
        try? progress.clear()
        progressEntity = nil
    }

    // MARK: - Helpers

    private func transition(to step: FounderStep) async throws {
        currentStep = step
        stepEnteredAt = .now
        await persist()
        await trackStepStart(step)
    }

    private func complete(step: FounderStep) async {
        let elapsed = Int(Date().timeIntervalSince(stepEnteredAt) * 1000)
        await analytics.track(.stepCompleted(flowType: .founder, stepID: step.rawValue, timeOnStepMs: elapsed))
    }

    private func trackStepStart(_ step: FounderStep) async {
        await analytics.track(.stepStarted(flowType: .founder, stepID: step.rawValue, stepIndex: step.index))
    }

    private func trackOnboardingCompleted() async {
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        let group = createdGroup
        await analytics.track(.groupCreated(
            hasVocabulary: draft.eventVocabulary != "evento",
            hasFrequency: draft.frequencyType != nil,
            finesEnabled: group?.finesEnabled ?? draft.finesEnabled,
            rotationMode: (group?.rotationMode ?? draft.rotationMode).rawValue,
            rulesCount: draft.rules.filter(\.enabled).count
        ))
        await analytics.track(.onboardingCompleted(flowType: .founder, totalTimeMs: elapsed))
    }

    private func persist() async {
        guard let entity = progressEntity else { return }
        entity.founderStep = currentStep
        entity.displayName = displayName
        entity.phoneE164 = phoneE164.isEmpty ? nil : phoneE164
        if let data = try? JSONEncoder().encode(draft) {
            entity.draftJSON = data
        }
        try? progress.save(entity)
    }
}
