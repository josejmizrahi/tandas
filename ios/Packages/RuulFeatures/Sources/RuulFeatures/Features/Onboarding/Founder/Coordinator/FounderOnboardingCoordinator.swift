import Foundation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class FounderOnboardingCoordinator {
    public private(set) var currentStep: FounderStep = .welcome
    public var draft: GroupDraft = .empty
    public var displayName: String = ""
    public var avatarLocalURL: URL?
    public var phoneE164: String = ""
    public private(set) var otpAttempts: Int = 0
    public private(set) var otpChannel: OTPChannel = .whatsapp
    public var pendingInvites: [PendingInvite] = []
    public private(set) var createdGroup: Group?
    public private(set) var error: OnboardingError?
    public private(set) var isLoading: Bool = false

    private let groupRepo: any GroupsRepository
    private let inviteRepo: any InviteRepository
    private let ruleRepo: any RuleRepository
    private let profileRepo: (any ProfileRepository)?
    private let otp: any OTPService
    private let analytics: any AnalyticsService
    private let progress: OnboardingProgressManager
    private let sessionId: UUID = UUID()
    private let startedAt: Date = .now
    private var stepEnteredAt: Date = .now
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "founder.onboarding")
    private var progressEntity: OnboardingProgress?

    public init(
        groupRepo: any GroupsRepository,
        inviteRepo: any InviteRepository,
        ruleRepo: any RuleRepository,
        otp: any OTPService,
        analytics: any AnalyticsService,
        progress: OnboardingProgressManager,
        profileRepo: (any ProfileRepository)? = nil
    ) {
        self.groupRepo = groupRepo
        self.inviteRepo = inviteRepo
        self.ruleRepo = ruleRepo
        self.profileRepo = profileRepo
        self.otp = otp
        self.analytics = analytics
        self.progress = progress
    }

    public func start() async {
        let entity = OnboardingProgress(flowType: .founder)
        try? progress.save(entity)
        progressEntity = entity
        await analytics.track(.onboardingStarted(flowType: .founder))
        // Skip-by-default policy (Beta 1 polish): welcome is pure friction
        // (just a "Hola + Empezar" screen). Land directly on identity so
        // the user types their name as the first action. The welcome step
        // is still emitted for analytics continuity.
        await complete(step: .welcome)
        try? await transition(to: .identity)
    }

    /// Restore from a previous in-progress entity. Reseats currentStep + draft.
    public func restore(from entity: OnboardingProgress) async {
        progressEntity = entity
        if let step = entity.founderStep {
            // Beta 1 skip-by-default: project legacy persisted steps
            // that are no longer reachable in the current flow onto
            // the closest visible step so users mid-flow on an old
            // build don't land on a screen the new flow doesn't show.
            //
            //   - welcome / templateSelect    → identity (no longer rendered)
            //   - vocabulary / rules / governance → invite (defaults backfilled)
            //   - phoneVerify / otp           → confirm (sign-in-first
            //     architecture: auth happens before onboarding starts,
            //     so these screens are unreachable; project them so an
            //     interrupted user lands on the completion screen and
            //     can finish the flow without re-doing work).
            switch step {
            case .welcome, .templateSelect:
                currentStep = .identity
            case .vocabulary, .rules, .governance:
                currentStep = .invite
            case .phoneVerify, .otp:
                currentStep = .confirm
            default:
                currentStep = step
            }
        }
        if let data = entity.draftJSON, let decoded = try? JSONDecoder().decode(GroupDraft.self, from: data) {
            draft = decoded
        }
        if let name = entity.displayName { displayName = name }
        if let phone = entity.phoneE164 { phoneE164 = phone }

        // Re-hydrate `createdGroup` for steps after .group. Without this, the
        // guards in advanceFromVocabulary / advanceFromRules / advanceFromInvite
        // (which check `createdGroup != nil`) silently no-op after an app
        // restart, leaving the user stuck on Continuar with no error shown.
        if currentStep.index > FounderStep.group.index {
            if let groupId = entity.createdGroupId,
               let detail = try? await groupRepo.get(groupId) {
                createdGroup = detail.group
                log.debug("restored createdGroup id=\(groupId)")
            } else if let groups = try? await groupRepo.listMine(),
                      let recent = groups.sorted(by: { $0.createdAt > $1.createdAt }).first {
                // Legacy fallback for progress rows persisted before
                // createdGroupId existed (or fetch by id failed). Take the
                // user's most recently created group and patch the entity.
                createdGroup = recent
                entity.createdGroupId = recent.id
                try? progress.save(entity)
                log.debug("recovered createdGroup via listMine fallback: \(recent.id)")
            } else {
                // No recoverable group for the current auth user. This happens
                // when the anon session that originally created the group was
                // lost (e.g., signOut from Settings, or a different anon was
                // promoted/replaced). Roll back to .group so the current user
                // creates a fresh group; their draft.name etc. is preserved.
                log.warning("could not restore createdGroup at step \(self.currentStep.rawValue); resetting to .group")
                currentStep = .group
                entity.founderStep = .group
                entity.createdGroupId = nil
                try? progress.save(entity)
            }
        }

        log.debug("restored at step \(self.currentStep.rawValue)")
        await analytics.track(.stepStarted(flowType: .founder, stepID: currentStep.rawValue, stepIndex: currentStep.index))
        stepEnteredAt = .now
    }

    // MARK: - Transitions

    public func advanceFromWelcome() async {
        await complete(step: .welcome)
        try? await transition(to: .identity)
    }

    public func advanceFromIdentity() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Sign-in-first architecture: the user is already authenticated
        // by the time they reach identity. Persist the typed name to
        // their `profiles` row so it shows up everywhere
        // (RuulAvatar fallbacks, member rows, group history). Without
        // this the trigger-seeded default ('Usuario' for phone-only,
        // email-prefix for Apple) would persist and the user would see
        // 'jose' instead of 'Jose Luis' across the app. Soft-fail —
        // the user can correct from EditProfileSheet later.
        if let profileRepo {
            do {
                try await profileRepo.updateDisplayName(trimmed)
            } catch {
                log.warning("updateDisplayName failed: \(error.localizedDescription)")
            }
        }
        await complete(step: .identity)
        // Beta 1 skip-by-default: V1 only ships `recurring_dinner` so the
        // selector has nothing to choose. Auto-assign and skip directly to
        // group identity. When Phase 2 ships a second template, restore
        // the visible templateSelect step.
        draft.template = TemplateRegistry.dinnerRecurringId
        await complete(step: .templateSelect)
        try? await transition(to: .group)
    }

    public func skipIdentity() async {
        displayName = ""
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.identity.rawValue))
        // Mirror advanceFromIdentity: skip templateSelect (V1 has 1 option).
        draft.template = TemplateRegistry.dinnerRecurringId
        await complete(step: .templateSelect)
        try? await transition(to: .group)
    }

    /// Sprint 1b: TemplateSelectorView auto-advances 600ms after selection.
    /// Pure transition — `draft.template` is set by the view itself when the
    /// user taps a card; this just moves the flow forward.
    public func advanceFromTemplateSelect() async {
        await complete(step: .templateSelect)
        try? await transition(to: .group)
    }

    public func advanceFromGroupIdentity() async {
        guard draft.isReadyToCreate, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let group = try await groupRepo.createInitial(draft)
            createdGroup = group
            // Sprint 1b: seed the 5 default Platform rules for the chosen
            // template. Idempotent — safe to retry if the user re-enters
            // this step after a connectivity blip. Failure here is non-fatal.
            if draft.template == TemplateRegistry.dinnerRecurringId {
                do {
                    _ = try await ruleRepo.seedDinnerTemplateRules(groupId: group.id)
                } catch {
                    log.warning("seedDinnerTemplateRules failed: \(error.localizedDescription)")
                }
            }
            await complete(step: .group)
            // Beta 1 skip-by-default: vocabulary / rules / governance all
            // have sensible template defaults already on the row. Skip to
            // invite (the next step that needs founder input). The skipped
            // steps are still marked completed for analytics continuity;
            // founder edits these post-onboarding via Settings → Reglas /
            // Gobernanza if/when they need to.
            await complete(step: .vocabulary)
            await complete(step: .rules)
            await complete(step: .governance)
            try? await transition(to: .invite)
        } catch {
            self.error = .createGroupFailed(error.localizedDescription)
            await analytics.track(.stepFailed(flowType: .founder, stepID: FounderStep.group.rawValue, errorType: "create_group"))
        }
    }

    public func advanceFromVocabulary() async {
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

    public func skipVocabulary() async {
        draft.frequencyType = nil
        draft.frequencyConfig = .empty
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.vocabulary.rawValue))
        try? await transition(to: .rules)
    }

    public func advanceFromRules() async {
        guard let group = createdGroup, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let enabledDrafts = draft.rules.filter(\.enabled)
        do {
            _ = try await ruleRepo.createInitialRules(groupId: group.id, drafts: enabledDrafts)
            // Primitives § 3 slice 3: write module membership directly. The
            // `update_group_config` RPC keeps owning rotation_mode (still a
            // first-class column on groups); fines toggle goes through the
            // dedicated module write-path so active_modules stays canonical
            // and the trigger derives fines_enabled.
            createdGroup = try await groupRepo.setModule(
                groupId: group.id,
                slug: GroupModule.basicFines.id,
                enabled: !enabledDrafts.isEmpty
            )
            let patch = GroupConfigPatch(rotationMode: draft.rotationMode)
            createdGroup = try await groupRepo.updateConfig(groupId: group.id, patch: patch)
            await complete(step: .rules)
            try? await transition(to: .governance)
        } catch {
            log.error("advanceFromRules failed: \(String(describing: error)) — message: \(error.localizedDescription)")
            self.error = .createRulesFailed(error.localizedDescription)
            await analytics.track(.stepFailed(flowType: .founder, stepID: FounderStep.rules.rawValue, errorType: "create_rules"))
        }
    }

    public func skipRules() async {
        draft.finesEnabled = false
        draft.rules = draft.rules.map {
            var copy = $0; copy.enabled = false; return copy
        }
        guard let group = createdGroup else { return }
        isLoading = true
        defer { isLoading = false }
        // Primitives § 3 slice 3: same split as advanceFromRules — module
        // toggle via setModule, rotation via updateConfig. Soft-fail on the
        // module call (try?) preserves the prior skip behaviour: a network
        // hiccup never dead-ends onboarding.
        if let updated = try? await groupRepo.setModule(
            groupId: group.id,
            slug: GroupModule.basicFines.id,
            enabled: false
        ) {
            createdGroup = updated
        }
        let patch = GroupConfigPatch(rotationMode: draft.rotationMode)
        if let updated = try? await groupRepo.updateConfig(groupId: group.id, patch: patch) {
            createdGroup = updated
        }
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.rules.rawValue))
        try? await transition(to: .governance)
    }

    /// Persists customised governance rules to `groups.governance`. Called
    /// when founder taps "Continuar" on `GovernanceConfigView`. If
    /// persistence fails the founder can retry; we don't block onboarding.
    public func advanceFromGovernance(rules: GovernanceRules) async {
        guard let group = createdGroup, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            createdGroup = try await groupRepo.updateGovernance(groupId: group.id, rules: rules)
            await complete(step: .governance)
            try? await transition(to: .invite)
        } catch {
            log.error("advanceFromGovernance failed: \(String(describing: error))")
            await analytics.track(.stepFailed(flowType: .founder, stepID: FounderStep.governance.rawValue, errorType: "update_governance"))
            // Soft-fail: keep template defaults already on the row, advance
            // anyway so onboarding doesn't dead-end.
            try? await transition(to: .invite)
        }
    }

    /// Skip governance step — keeps template defaults backfilled by
    /// migration 00019 / set at group creation.
    public func skipGovernance() async {
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.governance.rawValue))
        try? await transition(to: .invite)
    }

    public func advanceFromInvite() async {
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
        // Sign-in-first architecture: the user is already authenticated
        // by the time they reach this point in the founder flow (auth
        // happens in SignInView before onboarding starts). The legacy
        // phoneVerify / otp steps existed to promote an anon session to
        // a real one — no longer needed. Mark hasOnboarded and jump
        // straight to confirm. The .phoneVerify / .otp cases are still
        // emitted by `complete(step:)` for analytics continuity so the
        // funnel rate calc keeps working.
        OnboardingCompletion.mark()
        await complete(step: .phoneVerify)
        await complete(step: .otp)
        try? await transition(to: .confirm)
        await trackOnboardingCompleted()
    }

    public func skipInvite() async {
        pendingInvites.removeAll()
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.invite.rawValue))
        // Same skip-to-confirm path as advanceFromInvite — see comment
        // there for the rationale (sign-in-first architecture; auth
        // happened before onboarding, phoneVerify/otp redundant).
        OnboardingCompletion.mark()
        await complete(step: .phoneVerify)
        await complete(step: .otp)
        try? await transition(to: .confirm)
        await trackOnboardingCompleted()
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
            await analytics.track(.stepFailed(flowType: .founder, stepID: FounderStep.phoneVerify.rawValue, errorType: "otp_send"))
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

    public func resetOTPAttempts() {
        otpAttempts = 0
        error = nil
    }

    /// Skip the phone+OTP path: the user authenticated with Apple via the
    /// SiwA button on PhoneVerifyView (Supabase upgrades the current anon
    /// session to a real user when signInWithIdToken is called). Mark phone
    /// + otp steps complete and transition straight to confirmation.
    public func completeViaApple() async {
        OnboardingCompletion.mark()
        await complete(step: .phoneVerify)
        await complete(step: .otp)
        try? await transition(to: .confirm)
        await trackOnboardingCompleted()
        await analytics.track(.otpVerified(channel: "apple", attempts: 0))
    }

    public func finishOnboarding() async {
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
            finesEnabled: group.map { CapabilityResolver().finesEnabled(in: $0) } ?? draft.finesEnabled,
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
        entity.createdGroupId = createdGroup?.id
        if let data = try? JSONEncoder().encode(draft) {
            entity.draftJSON = data
        }
        try? progress.save(entity)
    }
}
