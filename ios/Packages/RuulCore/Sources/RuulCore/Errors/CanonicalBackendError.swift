import Foundation

/// Canonical raise messages emitted by the dev RPCs, parsed from `PostgrestError.message`.
/// Each case maps to a regex-friendly raise documented in `CanonicalRPCs_Contract.md`.
/// New cases land here as new RPCs come online; unknown messages bucket into `.unknown`.
public enum CanonicalBackendError: Sendable, Equatable {
    // Auth / membership
    case mustBeAuthenticated
    case callerNotActiveMember(groupId: UUID?)
    case lacksPermission(permission: String, groupId: UUID?)

    // Money — amounts & shapes
    case amountMustBePositive
    case amountRequired
    case customSplitMismatch(sum: Decimal?, expected: Decimal?)
    case invalidPaidToKind
    case resourceNotInGroup(resourceId: UUID?, groupId: UUID?)
    case crossTenantViolation

    // Invites
    case inviteRequiresEmailOrPhone
    case inviteNotFoundOrUsed
    case inviteExpired
    case inviteTokenMismatch

    // Mandates / authority
    case mandateDoesNotAuthorize(reason: String?)
    case ruleEvaluationDepthExceeded(eventId: UUID?, max: Int)

    // Profile
    case displayNameRequired
    case usernameAlreadyTaken

    // Anything we haven't classified yet
    case unknown(message: String)
}
