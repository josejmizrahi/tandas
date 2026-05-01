import Foundation
import OSLog

/// Analytics events tracked across the onboarding flow. All events carry
/// `flow_type` (founder | invited) and a `session_id` (UUID) attached by the
/// service so callers don't have to repeat them.
enum AnalyticsEvent: Sendable {
    case onboardingStarted(flowType: FlowKind)
    case stepStarted(flowType: FlowKind, stepID: String, stepIndex: Int)
    case stepCompleted(flowType: FlowKind, stepID: String, timeOnStepMs: Int)
    case stepSkipped(flowType: FlowKind, stepID: String)
    case stepFailed(flowType: FlowKind, stepID: String, errorType: String)
    case onboardingAbandoned(flowType: FlowKind, lastStepID: String, totalTimeMs: Int)
    case onboardingCompleted(flowType: FlowKind, totalTimeMs: Int)
    case groupCreated(hasVocabulary: Bool, hasFrequency: Bool, finesEnabled: Bool, rotationMode: String, rulesCount: Int)
    case memberJoinedViaInvite(timeFromInviteSentSeconds: Int?)
    case otpRequested(channel: String)
    case otpVerified(channel: String, attempts: Int)
    case otpFailed(channel: String, attempts: Int, reason: String)
    case inviteSent(method: String)

    enum FlowKind: String, Sendable { case founder, invited }

    /// Stable event name used by the analytics backend.
    var name: String {
        switch self {
        case .onboardingStarted:       return "onboarding_started"
        case .stepStarted:             return "onboarding_step_started"
        case .stepCompleted:           return "onboarding_step_completed"
        case .stepSkipped:             return "onboarding_step_skipped"
        case .stepFailed:              return "onboarding_step_failed"
        case .onboardingAbandoned:     return "onboarding_abandoned"
        case .onboardingCompleted:     return "onboarding_completed"
        case .groupCreated:            return "group_created"
        case .memberJoinedViaInvite:   return "member_joined_via_invite"
        case .otpRequested:            return "otp_requested"
        case .otpVerified:             return "otp_verified"
        case .otpFailed:               return "otp_failed"
        case .inviteSent:              return "invite_sent"
        }
    }

    /// Per-event properties to send up. Keys match the prompt's spec.
    var properties: [String: AnalyticsValue] {
        switch self {
        case .onboardingStarted(let f):
            return ["flow_type": .string(f.rawValue)]
        case .stepStarted(let f, let id, let idx):
            return ["flow_type": .string(f.rawValue), "step_id": .string(id), "step_index": .int(idx)]
        case .stepCompleted(let f, let id, let ms):
            return ["flow_type": .string(f.rawValue), "step_id": .string(id), "time_on_step_ms": .int(ms)]
        case .stepSkipped(let f, let id):
            return ["flow_type": .string(f.rawValue), "step_id": .string(id)]
        case .stepFailed(let f, let id, let err):
            return ["flow_type": .string(f.rawValue), "step_id": .string(id), "error_type": .string(err)]
        case .onboardingAbandoned(let f, let last, let ms):
            return ["flow_type": .string(f.rawValue), "last_step_id": .string(last), "time_total_ms": .int(ms)]
        case .onboardingCompleted(let f, let ms):
            return ["flow_type": .string(f.rawValue), "total_time_ms": .int(ms)]
        case .groupCreated(let hv, let hf, let fe, let rm, let rc):
            return [
                "has_vocabulary": .bool(hv), "has_frequency": .bool(hf),
                "fines_enabled": .bool(fe), "rotation_mode": .string(rm),
                "rules_count": .int(rc)
            ]
        case .memberJoinedViaInvite(let secs):
            return ["time_from_invite_sent_seconds": secs.map(AnalyticsValue.int) ?? .null]
        case .otpRequested(let ch):
            return ["channel": .string(ch)]
        case .otpVerified(let ch, let att):
            return ["channel": .string(ch), "attempts": .int(att)]
        case .otpFailed(let ch, let att, let reason):
            return ["channel": .string(ch), "attempts": .int(att), "reason": .string(reason)]
        case .inviteSent(let method):
            return ["method": .string(method)]
        }
    }
}

enum AnalyticsValue: Sendable {
    case string(String), int(Int), double(Double), bool(Bool), null
}

protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent) async
    func setUser(_ userId: UUID, properties: [String: AnalyticsValue]) async
}

/// No-op + log impl. Used when no real analytics backend is wired.
final class LogAnalyticsService: AnalyticsService {
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "analytics")

    func track(_ event: AnalyticsEvent) async {
        log.debug("track \(event.name) \(String(describing: event.properties))")
    }

    func setUser(_ userId: UUID, properties: [String: AnalyticsValue]) async {
        log.debug("setUser \(userId) \(String(describing: properties))")
    }
}

/// Mock for tests.
actor MockAnalyticsService: AnalyticsService {
    private(set) var trackedEvents: [AnalyticsEvent] = []
    private(set) var userId: UUID?
    private(set) var userProperties: [String: AnalyticsValue] = [:]

    func track(_ event: AnalyticsEvent) async {
        trackedEvents.append(event)
    }

    func setUser(_ userId: UUID, properties: [String: AnalyticsValue]) async {
        self.userId = userId
        self.userProperties = properties
    }

    func reset() {
        trackedEvents.removeAll()
        userId = nil
        userProperties = [:]
    }
}
