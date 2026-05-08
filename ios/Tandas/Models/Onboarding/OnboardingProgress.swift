import Foundation
import SwiftData

/// Persistent record of an in-progress onboarding flow. SwiftData entity.
///
/// One row at a time per local user; new flow → new row, old row deleted.
/// `flowType` distinguishes founder vs invited; the appropriate `*StepRaw`
/// holds the resume point.
@Model
final class OnboardingProgress {
    @Attribute(.unique) var id: UUID
    var flowTypeRaw: String
    var founderStepRaw: String?
    var invitedStepRaw: String?
    var inviteCode: String?              // invited flow
    var draftJSON: Data?                 // encoded GroupDraft snapshot (founder)
    var displayName: String?
    var phoneE164: String?
    var createdGroupId: UUID?            // founder: id of the group created at step .group
    var startedAt: Date
    var lastUpdatedAt: Date

    init(
        id: UUID = UUID(),
        flowType: FlowType,
        inviteCode: String? = nil
    ) {
        self.id = id
        self.flowTypeRaw = flowType.rawValue
        self.inviteCode = inviteCode
        self.startedAt = Date()
        self.lastUpdatedAt = Date()
    }

    enum FlowType: String, Sendable {
        case founder, invited
    }

    var flowType: FlowType {
        FlowType(rawValue: flowTypeRaw) ?? .founder
    }

    var founderStep: FounderStep? {
        get { founderStepRaw.flatMap(FounderStep.init(rawValue:)) }
        set { founderStepRaw = newValue?.rawValue }
    }

    var invitedStep: InvitedStep? {
        get { invitedStepRaw.flatMap(InvitedStep.init(rawValue:)) }
        set { invitedStepRaw = newValue?.rawValue }
    }
}

enum FounderStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case identity        // founder personal name + avatar
    case templateSelect  // platform template (Sprint 1b — Cena recurrente only in V1)
    case group           // group identity (name + cover)
    case vocabulary
    case rules
    case governance      // Bloque 6 — who can modify rules, voting config
    case invite
    case phoneVerify
    case otp
    case confirm

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Beta 1 skip-by-default: steps that the coordinator auto-completes
    /// without showing UI (template has only one option in V1; vocabulary/
    /// rules/governance use template defaults editable post-onboarding
    /// via Settings). Drives the progress bar denominator so the user
    /// sees realistic completion %.
    static let visibleSteps: [FounderStep] = [
        .identity, .group, .invite, .phoneVerify, .otp, .confirm
    ]

    /// Index within `visibleSteps`, or the closest-prior visible-step slot
    /// for steps that auto-skip. Used by progress views so the bar never
    /// regresses or jumps disproportionately.
    var visibleIndex: Int {
        if let idx = Self.visibleSteps.firstIndex(of: self) { return idx }
        switch self {
        case .welcome:        return 0  // pre-identity
        case .templateSelect: return 0  // between identity and group
        case .vocabulary,
             .rules,
             .governance:     return 1  // between group and invite
        default:              return 0
        }
    }

    /// Fraction in [0, 1] for progress display.
    var progressFraction: Double {
        let total = max(1, Self.visibleSteps.count - 1)
        return Double(visibleIndex) / Double(total)
    }
}

enum InvitedStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case identity
    case phoneVerify
    case otp
    case tour

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
