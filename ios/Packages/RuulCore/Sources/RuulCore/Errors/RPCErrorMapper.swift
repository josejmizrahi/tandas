import Foundation
import Supabase

/// Translates the dev contract's regex-friendly raise messages into
/// `RuulError`. The full catalog of recognised raises lives in
/// `Plans/Active/CanonicalRPCs_Contract.md` §16/§17. Any string the
/// mapper doesn't recognise falls through to `.unknown(message:)`.
public enum RPCErrorMapper {
    public static func map(_ error: any Error) -> RuulError {
        if let ruul = error as? RuulError { return ruul }
        if let pg = error as? PostgrestError { return mapPostgrest(pg) }
        if (error as NSError).domain == NSURLErrorDomain {
            return .network(message: (error as NSError).localizedDescription)
        }
        if error is CancellationError { return .cancelled }
        return .unexpected(message: (error as NSError).localizedDescription)
    }

    private static func mapPostgrest(_ pg: PostgrestError) -> RuulError {
        .backend(parse(pg.message))
    }

    static func parse(_ raw: String) -> CanonicalBackendError {
        let s = raw.lowercased()

        if s.contains("must be authenticated") {
            return .mustBeAuthenticated
        }
        if s.contains("caller is not an active member of group") {
            return .callerNotActiveMember(groupId: extractUUID(after: "group", in: raw))
        }
        if let permission = matchPermission(raw) {
            return .lacksPermission(permission: permission, groupId: extractUUID(after: "in group", in: raw))
        }
        if s.contains("amount must be positive") { return .amountMustBePositive }
        if s.contains("amount required") { return .amountRequired }
        if s.contains("custom split sum") && s.contains("does not match amount") {
            return .customSplitMismatch(sum: extractDecimal(after: "sum", in: raw),
                                       expected: extractDecimal(after: "amount", in: raw))
        }
        if s.contains("invalid paid_to_kind") { return .invalidPaidToKind }
        if s.contains("resource") && s.contains("not in group") {
            return .resourceNotInGroup(
                resourceId: extractUUID(after: "resource", in: raw),
                groupId: extractUUID(after: "group", in: raw)
            )
        }
        if s.contains("cross-tenant violation") { return .crossTenantViolation }

        if s.contains("display_name required") { return .displayNameRequired }
        if s.contains("username already taken") { return .usernameAlreadyTaken }

        if s.contains("invalid purpose kind") { return .invalidPurposeKind }
        if s.contains("invalid purpose visibility") { return .invalidPurposeVisibility }
        if s.contains("purpose body required") { return .purposeBodyRequired }

        if s.contains("rule title required") { return .ruleTitleRequired }
        if s.contains("rule body required") { return .ruleBodyRequired }
        if s.contains("invalid rule type") { return .invalidRuleType }
        if s.contains("invalid rule severity") { return .invalidRuleSeverity }
        if s.contains("rule not found") { return .ruleNotFound }

        if s.contains("invalid resource type") { return .invalidResourceType }
        if s.contains("resource name required") { return .resourceNameRequired }
        if s.contains("invalid resource visibility") { return .invalidResourceVisibility }
        if s.contains("invalid ownership kind") { return .invalidOwnershipKind }
        if s.contains("owner membership not in group") {
            return .ownerMembershipNotInGroup(groupId: extractUUID(after: "group", in: raw))
        }
        if s.contains("custodian membership not in group") {
            return .custodianMembershipNotInGroup(groupId: extractUUID(after: "group", in: raw))
        }
        if s.contains("resource not found") { return .resourceNotFound }

        if s.contains("invalid decision style") { return .invalidDecisionStyle }
        if s.contains("quorum_min must be >= 1") { return .quorumMinTooSmall }

        if s.contains("monetary sanction requires positive amount") { return .monetarySanctionRequiresAmountUnit }

        if s.contains("invite requires email or phone") { return .inviteRequiresEmailOrPhone }
        if s.contains("invite not found or already used") { return .inviteNotFoundOrUsed }
        if s.contains("invite expired") { return .inviteExpired }
        if s.contains("invite token mismatch") { return .inviteTokenMismatch }

        if s.contains("mandate does not authorize this action") {
            return .mandateDoesNotAuthorize(reason: extractTail(after: ":", in: raw))
        }
        if s.contains("rule evaluation depth") && s.contains("exceeds max") {
            return .ruleEvaluationDepthExceeded(
                eventId: extractUUID(after: "event", in: raw),
                max: 5
            )
        }

        return .unknown(message: raw)
    }

    // MARK: - Tiny extractors

    private static func matchPermission(_ raw: String) -> String? {
        // Form: "caller lacks permission <key> in group <uuid>"
        let s = raw.lowercased()
        guard let range = s.range(of: "caller lacks permission ") else { return nil }
        let tail = raw[range.upperBound...]
        return String(tail.split(separator: " ", maxSplits: 1).first ?? "")
    }

    private static func extractUUID(after needle: String, in raw: String) -> UUID? {
        // Scan for any UUID-looking token after the needle.
        let s = raw.lowercased()
        guard let range = s.range(of: needle.lowercased()) else { return nil }
        let tail = String(raw[range.upperBound...])
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let match = tail.range(of: pattern, options: .regularExpression) else { return nil }
        return UUID(uuidString: String(tail[match]))
    }

    private static func extractDecimal(after needle: String, in raw: String) -> Decimal? {
        let s = raw.lowercased()
        guard let range = s.range(of: needle.lowercased()) else { return nil }
        let tail = String(raw[range.upperBound...])
        let pattern = #"-?\d+(\.\d+)?"#
        guard let match = tail.range(of: pattern, options: .regularExpression) else { return nil }
        return Decimal(string: String(tail[match]))
    }

    private static func extractTail(after sep: String, in raw: String) -> String? {
        guard let range = raw.range(of: sep) else { return nil }
        return raw[range.upperBound...].trimmingCharacters(in: .whitespaces).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
