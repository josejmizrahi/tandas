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
    case invite
    case phoneVerify
    case otp
    case confirm

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

enum InvitedStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case identity
    case phoneVerify
    case otp
    case tour

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
