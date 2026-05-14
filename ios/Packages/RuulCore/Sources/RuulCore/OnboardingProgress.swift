import Foundation
import SwiftData

/// Persistent record of an in-progress onboarding flow. SwiftData entity.
///
/// One row at a time per local user; new flow → new row, old row deleted.
/// `flowType` distinguishes founder vs invited; the appropriate `*StepRaw`
/// holds the resume point.
@Model
public final class OnboardingProgress {
    @Attribute(.unique) public var id: UUID
    public var flowTypeRaw: String
    public var founderStepRaw: String?
    public var invitedStepRaw: String?
    public var inviteCode: String?              // invited flow
    public var draftJSON: Data?                 // encoded GroupDraft snapshot (founder)
    public var displayName: String?
    public var phoneE164: String?
    public var createdGroupId: UUID?            // founder: id of the group created at step .group
    public var startedAt: Date
    public var lastUpdatedAt: Date

    public init(
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

    public enum FlowType: String, Sendable {
        case founder, invited
    }

    public var flowType: FlowType {
        FlowType(rawValue: flowTypeRaw) ?? .founder
    }

    public var founderStep: FounderStep? {
        get { founderStepRaw.flatMap(FounderStep.init(rawValue:)) }
        set { founderStepRaw = newValue?.rawValue }
    }

    public var invitedStep: InvitedStep? {
        get { invitedStepRaw.flatMap(InvitedStep.init(rawValue:)) }
        set { invitedStepRaw = newValue?.rawValue }
    }
}

public enum FounderStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case identity   // founder personal name + avatar
    case group      // group identity (name + cover)
    case preset     // choose starter preset OR "empezar de cero"
    case consent    // Beta 1 W3 B-3.4 — read the template's suggested rules
                    // before inviting members. Only entered when the chosen
                    // preset seeded ≥1 rule; "Empezar de cero" skips straight
                    // to invite.
    case invite     // invite members (optional skip)
    case confirm    // landing screen

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static let visibleSteps: [FounderStep] = [
        .identity, .group, .preset, .consent, .invite, .confirm
    ]

    public var visibleIndex: Int {
        if let idx = Self.visibleSteps.firstIndex(of: self) { return idx }
        switch self {
        case .welcome: return 0
        default:       return 0
        }
    }

    public var progressFraction: Double {
        let total = max(1, Self.visibleSteps.count - 1)
        return Double(visibleIndex) / Double(total)
    }
}

public enum InvitedStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case identity
    case phoneVerify
    case otp
    case tour

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
