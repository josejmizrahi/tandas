import Foundation
import OSLog
import RuulUI
import RuulCore

/// Founder onboarding flow per OpenPlatform Phase S1 (Founder Welcome).
///
/// 5-step linear flow with optional skips:
///
///   welcome   →  (auto)         enter the funnel
///   identity  →  name + avatar  (skip allowed)
///   group     →  group name
///   preset    →  3-card pick: recurring_dinner / shared_resource / blank
///   invite    →  phone invites  (skip allowed)
///   confirm   →  landing
///
/// Auth is sign-in-first — by the time the coordinator runs, the user
/// already has a real session. No phone-verify / OTP steps inside the
/// flow.
@Observable @MainActor
public final class FounderOnboardingCoordinator {
    public private(set) var currentStep: FounderStep = .welcome
    public var draft: GroupDraft = .empty
    public var displayName: String = ""
    public var avatarLocalURL: URL?
    public var pendingInvites: [PendingInvite] = []
    public private(set) var createdGroup: Group?
    public private(set) var error: OnboardingError?
    public private(set) var isLoading: Bool = false

    /// Beta 1 W3 B-3.4: rules seeded by the chosen template. Populated by
    /// `selectPreset(_:)` so the consent step can render them before
    /// inviting members. Empty when the user picked "Empezar de cero"
    /// (no template) — in that case the consent step is skipped.
    public private(set) var templateRulePreviews: [OnboardingRule] = []

    private let groupRepo: any GroupsRepository
    private let inviteRepo: any InviteRepository
    private let ruleRepo: any RuleRepository
    private let profileRepo: (any ProfileRepository)?
    private let analytics: any AnalyticsService
    private let progress: any OnboardingProgressPersisting
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
        progress: any OnboardingProgressPersisting,
        profileRepo: (any ProfileRepository)? = nil
    ) {
        self.groupRepo = groupRepo
        self.inviteRepo = inviteRepo
        self.ruleRepo = ruleRepo
        self.profileRepo = profileRepo
        // `otp` is part of the legacy init signature but unused post S1.
        // Kept so AppState's existing wiring compiles without refactor.
        _ = otp
        self.analytics = analytics
        self.progress = progress
    }

    public func start() async {
        let entity = OnboardingProgress(flowType: .founder)
        try? progress.save(entity)
        progressEntity = entity
        await analytics.track(.onboardingStarted(flowType: .founder))
        await complete(step: .welcome)
        try? await transition(to: .identity)
    }

    /// Restore from a persisted entity. Projects legacy step ids onto
    /// the new step set so users mid-flow on an old build land on a
    /// sensible step. Reads the raw string directly so values that no
    /// longer decode into the current `FounderStep` enum still project
    /// onto a usable step.
    public func restore(from entity: OnboardingProgress) async {
        progressEntity = entity
        if let raw = entity.founderStepRaw {
            currentStep = projectLegacyStepRaw(raw)
        }
        if let data = entity.draftJSON, let decoded = try? JSONDecoder().decode(GroupDraft.self, from: data) {
            draft = decoded
        }
        if let name = entity.displayName { displayName = name }

        if currentStep.index > FounderStep.group.index {
            if let groupId = entity.createdGroupId,
               let detail = try? await groupRepo.get(groupId) {
                createdGroup = detail.group
            } else if let groups = try? await groupRepo.listMine(),
                      let recent = groups.sorted(by: { $0.createdAt > $1.createdAt }).first {
                createdGroup = recent
                entity.createdGroupId = recent.id
                try? progress.save(entity)
            } else {
                log.warning("could not restore createdGroup at step \(self.currentStep.rawValue); resetting to .group")
                currentStep = .group
                entity.founderStep = .group
                entity.createdGroupId = nil
                try? progress.save(entity)
            }
        }

        await analytics.track(.stepStarted(flowType: .founder, stepID: currentStep.rawValue, stepIndex: currentStep.index))
        stepEnteredAt = .now
    }

    /// Map legacy raw step ids (pre-S1) onto the new step set.
    private func projectLegacyStepRaw(_ raw: String) -> FounderStep {
        switch raw {
        case "welcome":         return .welcome
        case "identity":        return .identity
        case "group":           return .group
        case "preset":          return .preset
        case "invite":          return .invite
        case "confirm":         return .confirm
        case "templateSelect":  return .preset    // legacy → preset
        case "consent":         return .consent
        case "vocabulary",
             "rules",
             "governance":      return .invite    // post-group legacy steps
        case "phoneVerify", "otp": return .confirm  // auth already done
        default:                return .welcome
        }
    }

    // MARK: - Transitions

    public func advanceFromWelcome() async {
        await complete(step: .welcome)
        try? await transition(to: .identity)
    }

    public func advanceFromIdentity() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let profileRepo {
            do {
                try await profileRepo.updateDisplayName(trimmed)
            } catch {
                log.warning("updateDisplayName failed: \(error.localizedDescription)")
            }
        }
        await complete(step: .identity)
        try? await transition(to: .group)
    }

    public func skipIdentity() async {
        displayName = ""
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.identity.rawValue))
        try? await transition(to: .group)
    }

    public func advanceFromGroupIdentity() async {
        guard draft.isReadyToCreate, !isLoading else { return }
        await complete(step: .group)
        try? await transition(to: .preset)
    }

    /// Pick a preset (or "empezar de cero"). Creates the group with the
    /// corresponding base_template + template defaults (modules,
    /// governance, vocabulary). For "blank" the group is bare —
    /// active_modules = [], no vocabulary preset.
    public func selectPreset(_ preset: OnboardingPreset) async {
        guard let _ = draft.isReadyToCreate ? draft.name : nil,
              !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        draft.template = preset.templateId ?? ""
        if let vocab = preset.suggestedVocabulary {
            draft.eventVocabulary = vocab
        }

        // Beta 1 W4 F-4.5: emit per-preset pick so the analytics pipeline
        // can split funnel by template before group creation completes.
        let beta = BetaAnalytics(analytics: analytics)
        await beta.groupTemplatePicked(templateId: preset.templateId)

        do {
            let group = try await groupRepo.createInitial(draft)
            createdGroup = group

            // Seed module rules ONLY when the preset has a template — bare
            // groups start with no rules and let the user add them via the
            // ResourceWizard on demand.
            //
            // Beta 1 W3 B-3.4: cache the seeded rules so the consent step
            // can display them. For "Empezar de cero" (no templateId) the
            // cache stays empty and the consent step is skipped.
            if let templateId = preset.templateId {
                do {
                    templateRulePreviews = try await ruleRepo.seedTemplateRules(
                        templateId: templateId,
                        groupId: group.id
                    )
                } catch {
                    log.warning("seedTemplateRules failed: \(error.localizedDescription)")
                    templateRulePreviews = []
                }
            } else {
                templateRulePreviews = []
            }

            await complete(step: .preset)
            // Route through consent only when there are rules to consent
            // to. Blank presets fast-forward to the invite step.
            try? await transition(to: templateRulePreviews.isEmpty ? .invite : .consent)
        } catch {
            self.error = .createGroupFailed(error.localizedDescription)
            await analytics.track(.stepFailed(
                flowType: .founder,
                stepID: FounderStep.preset.rawValue,
                errorType: "create_group"
            ))
        }
    }

    /// Beta 1 W3 B-3.4: consent step exit. Pure forward — no mutation
    /// because the rules were seeded in modo sugerencia (`isActive=false`,
    /// per B-1.1) at preset selection time. The founder activates them
    /// later from the Rules tab. Step exists to surface the rules so the
    /// first-time user understands what's behind the curtain.
    public func advanceFromConsent() async {
        await complete(step: .consent)
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
        OnboardingCompletion.mark()
        try? await transition(to: .confirm)
        await trackOnboardingCompleted()
    }

    public func skipInvite() async {
        pendingInvites.removeAll()
        await analytics.track(.stepSkipped(flowType: .founder, stepID: FounderStep.invite.rawValue))
        OnboardingCompletion.mark()
        try? await transition(to: .confirm)
        await trackOnboardingCompleted()
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
        let finesEnabled = createdGroup.map { CapabilityResolver().finesEnabled(in: $0) } ?? false
        await analytics.track(.groupCreated(
            hasVocabulary: draft.eventVocabulary != "evento",
            hasFrequency: false,
            finesEnabled: finesEnabled,
            rotationMode: "n/a",
            rulesCount: 0
        ))
        await analytics.track(.onboardingCompleted(flowType: .founder, totalTimeMs: elapsed))
    }

    private func persist() async {
        guard let entity = progressEntity else { return }
        entity.founderStep = currentStep
        entity.displayName = displayName
        entity.createdGroupId = createdGroup?.id
        if let data = try? JSONEncoder().encode(draft) {
            entity.draftJSON = data
        }
        try? progress.save(entity)
    }
}

/// Starter presets surfaced in PresetPickerView. Maps user-facing copy
/// to the server-side template id (or null for "empezar de cero").
public struct OnboardingPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let icon: String
    public let sampleResources: [String]
    /// nil = "empezar de cero" → bare group with no template.
    public let templateId: String?
    public let suggestedVocabulary: String?

    public init(
        id: String,
        displayName: String,
        summary: String,
        icon: String,
        sampleResources: [String],
        templateId: String?,
        suggestedVocabulary: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.icon = icon
        self.sampleResources = sampleResources
        self.templateId = templateId
        self.suggestedVocabulary = suggestedVocabulary
    }

    public static let recurringDinner = OnboardingPreset(
        id: "recurring_dinner",
        displayName: "Reuniones recurrentes",
        summary: "Cenas, juntas, partidos. RSVP + check-in + multas opcionales.",
        icon: "calendar.badge.clock",
        sampleResources: ["Cena semanal", "Multas por no-show", "Host rotativo"],
        templateId: TemplateRegistry.dinnerRecurringId,
        suggestedVocabulary: "cena"
    )

    public static let sharedResource = OnboardingPreset(
        id: "shared_resource",
        displayName: "Activo compartido",
        summary: "Palco, casa, cancha. Slots + reservas + rotación.",
        icon: "person.3.sequence",
        sampleResources: ["Slots de fin de semana", "Reservas", "Rotación de uso"],
        templateId: "shared_resource"
    )

    public static let blank = OnboardingPreset(
        id: "blank",
        displayName: "Empezar de cero",
        summary: "Grupo sin reglas ni módulos. Tú decides qué agregar después.",
        icon: "square.dashed",
        sampleResources: ["Sin recursos preseteados", "Agrega lo que necesites"],
        templateId: nil
    )

    public static let all: [OnboardingPreset] = [.recurringDinner, .sharedResource, .blank]
}
